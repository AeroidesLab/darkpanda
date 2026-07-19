//! Middleware for decoding

use std::{
    future::Future,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context, Poll, ready},
};

use bytes::Buf;
use http::{Request, Response};
use http_body::Body;
use pin_project_lite::pin_project;
use tower::{Layer, Service};
use tower_http::decompression::{self, DecompressionBody, ResponseFuture};

use crate::config::RequestConfig;

/// Configuration for supported content-encoding algorithms.
///
/// `AcceptEncoding` controls which compression formats are enabled for decoding
/// response bodies. Each field corresponds to a specific algorithm and is only
/// available if the corresponding feature is enabled.
#[derive(Clone)]
pub(crate) struct AcceptEncoding {
    #[cfg(feature = "gzip")]
    pub(crate) gzip: bool,
    #[cfg(feature = "brotli")]
    pub(crate) brotli: bool,
    #[cfg(feature = "zstd")]
    pub(crate) zstd: bool,
    #[cfg(feature = "deflate")]
    pub(crate) deflate: bool,
}

/// Layer that adds response body decompression to a service.
#[derive(Clone)]
pub struct DecompressionLayer {
    accept: AcceptEncoding,
}

/// Service that decompresses response bodies based on the [`AcceptEncoding`] configuration.
#[derive(Clone)]
pub struct Decompression<S>(
    Option<decompression::Decompression<EncodedBodySizeService<S>>>,
);

/// Shared byte counter installed before tower-http's decompression layer.
///
/// `Content-Length` is only a hint: HTTP/2 responses may omit it and streamed
/// encodings do not have to know it up front. Counting the original Body
/// frames is what makes Resource Timing's encodedBodySize exact for gzip,
/// brotli, deflate, zstd, chunked HTTP/1.1 and HTTP/2 alike.
#[derive(Debug)]
pub(crate) struct EncodedBodySizeMetadata {
    observed: AtomicU64,
    declared: Option<u64>,
    content_encoding: Option<http::HeaderValue>,
}

impl EncodedBodySizeMetadata {
    pub(crate) fn observed(&self) -> u64 {
        self.observed.load(Ordering::Acquire)
    }

    pub(crate) fn declared(&self) -> Option<u64> {
        self.declared
    }

    pub(crate) fn content_encoding(&self) -> Option<&http::HeaderValue> {
        self.content_encoding.as_ref()
    }
}

#[derive(Clone)]
struct EncodedBodySizeService<S> {
    inner: S,
}

pin_project! {
    pub struct EncodedBodySizeFuture<F> {
        #[pin]
        inner: F,
    }
}

pin_project! {
    pub struct EncodedBodySizeBody<B> {
        #[pin]
        inner: B,
        metadata: Arc<EncodedBodySizeMetadata>,
    }
}

impl<S, ReqBody, ResBody> Service<Request<ReqBody>> for EncodedBodySizeService<S>
where
    S: Service<Request<ReqBody>, Response = Response<ResBody>>,
{
    type Response = Response<EncodedBodySizeBody<ResBody>>;
    type Error = S::Error;
    type Future = EncodedBodySizeFuture<S::Future>;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.inner.poll_ready(cx)
    }

    fn call(&mut self, req: Request<ReqBody>) -> Self::Future {
        EncodedBodySizeFuture {
            inner: self.inner.call(req),
        }
    }
}

impl<F, B, E> Future for EncodedBodySizeFuture<F>
where
    F: Future<Output = Result<Response<B>, E>>,
{
    type Output = Result<Response<EncodedBodySizeBody<B>>, E>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let response = match ready!(self.project().inner.poll(cx)) {
            Ok(response) => response,
            Err(error) => return Poll::Ready(Err(error)),
        };
        let (mut parts, body) = response.into_parts();
        let metadata = Arc::new(EncodedBodySizeMetadata {
            observed: AtomicU64::new(0),
            declared: parts
                .headers
                .get(http::header::CONTENT_LENGTH)
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.parse().ok()),
            content_encoding: parts.headers.get(http::header::CONTENT_ENCODING).cloned(),
        });
        parts.extensions.insert(Arc::clone(&metadata));
        Poll::Ready(Ok(Response::from_parts(
            parts,
            EncodedBodySizeBody {
                inner: body,
                metadata,
            },
        )))
    }
}

impl<B> Body for EncodedBodySizeBody<B>
where
    B: Body,
{
    type Data = B::Data;
    type Error = B::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<http_body::Frame<Self::Data>, Self::Error>>> {
        let this = self.project();
        let polled = this.inner.poll_frame(cx);
        if let Poll::Ready(Some(Ok(frame))) = &polled {
            if let Some(data) = frame.data_ref() {
                this.metadata
                    .observed
                    .fetch_add(data.remaining() as u64, Ordering::Release);
            }
        }
        polled
    }

    fn is_end_stream(&self) -> bool {
        self.inner.is_end_stream()
    }

    fn size_hint(&self) -> http_body::SizeHint {
        self.inner.size_hint()
    }
}

// ===== AcceptEncoding =====

impl Default for AcceptEncoding {
    fn default() -> AcceptEncoding {
        AcceptEncoding {
            #[cfg(feature = "gzip")]
            gzip: true,
            #[cfg(feature = "brotli")]
            brotli: true,
            #[cfg(feature = "zstd")]
            zstd: true,
            #[cfg(feature = "deflate")]
            deflate: true,
        }
    }
}

impl_request_config_value!(AcceptEncoding);

// ===== impl DecompressionLayer =====

impl DecompressionLayer {
    /// Creates a new [`DecompressionLayer`] with the specified [`AcceptEncoding`].
    #[inline(always)]
    pub fn new(accept: AcceptEncoding) -> Self {
        Self { accept }
    }
}

impl<S> Layer<S> for DecompressionLayer {
    type Service = Decompression<S>;

    #[inline(always)]
    fn layer(&self, service: S) -> Self::Service {
        let decoder = decompression::Decompression::new(EncodedBodySizeService { inner: service })
            .no_br()
            .no_deflate()
            .no_gzip()
            .no_zstd();
        Decompression(Some(Decompression::<S>::accept_in_place(
            decoder,
            &self.accept,
        )))
    }
}

// ===== impl Decompression =====

impl<S> Decompression<S> {
    const BUG_MSG: &str = "[BUG] Decompression service not initialized; bug in setup";

    fn accept_in_place(
        mut decoder: decompression::Decompression<EncodedBodySizeService<S>>,
        accept: &AcceptEncoding,
    ) -> decompression::Decompression<EncodedBodySizeService<S>> {
        #[cfg(feature = "gzip")]
        {
            decoder = decoder.gzip(accept.gzip);
        }

        #[cfg(feature = "deflate")]
        {
            decoder = decoder.deflate(accept.deflate);
        }

        #[cfg(feature = "brotli")]
        {
            decoder = decoder.br(accept.brotli);
        }

        #[cfg(feature = "zstd")]
        {
            decoder = decoder.zstd(accept.zstd);
        }

        decoder
    }
}

impl<S, ReqBody, ResBody> Service<Request<ReqBody>> for Decompression<S>
where
    S: Service<Request<ReqBody>, Response = Response<ResBody>>,
    ReqBody: Body,
    ResBody: Body,
{
    type Response = Response<DecompressionBody<EncodedBodySizeBody<ResBody>>>;
    type Error = S::Error;
    type Future = ResponseFuture<EncodedBodySizeFuture<S::Future>>;

    #[inline(always)]
    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.0.as_mut().expect(Self::BUG_MSG).poll_ready(cx)
    }

    fn call(&mut self, req: Request<ReqBody>) -> Self::Future {
        if let Some(accept_encoding) = RequestConfig::<AcceptEncoding>::get(req.extensions()) {
            if let Some(decoder) = self.0.take() {
                self.0
                    .replace(Decompression::accept_in_place(decoder, accept_encoding));
            }
            debug_assert!(self.0.is_some());
        }

        self.0.as_mut().expect(Self::BUG_MSG).call(req)
    }
}
