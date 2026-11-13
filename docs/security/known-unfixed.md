# Known vulnerabilities without an upstream fix

The CVEs below cover a version this repository builds, and no release of
the project that owns the code fixes them yet. Everything that has a fixed
release is on it (see UPDATE.md). Checked on 2026-11-12 against the CVE
records (cve.org), OSV, the Debian security tracker and NVD; rechecked
before every release.

"Not in this build" means the code is not compiled into the binaries: the
library or the FFmpeg component is not enabled on any platform.

## FFmpeg 9.0.2 (125 CVEs)

Every record below says "FFmpeg ... through 9.0.2". No newer release exists
on 2026-11-12: 9.0.2 is the last tag of the 9.0 line, and 9.1 has no release
yet. They move to the next FFmpeg point release when it is out.

| CVE | published | where |
|---|---|---|
| CVE-2026-107675 | 2026-10-08 | missing host key verification vulnerability in the libssh-based sftp protocol handler *(not in this build)* |
| CVE-2026-107676 | 2026-10-08 | uninitialized memory disclosure vulnerability in av_dynamic_hdr_plus_to_t35() |
| CVE-2026-107677 | 2026-10-08 | denial of service vulnerability in the DASH demuxer |
| CVE-2026-107678 | 2026-10-08 | stack exhaustion vulnerability in av_encryption_init_info_free() in libavutil/encryption_info.c, |
| CVE-2026-107696 | 2026-10-08 | infinite loop vulnerability in ff_rtsp_connect() in libavformat/rtsp.c |
| CVE-2026-120210 | 2026-10-31 | path traversal vulnerability in the IMF demuxer |
| CVE-2026-120243 | 2026-11-01 | use of uninitialized variable vulnerability in the Go2Meeting decoder |
| CVE-2026-120244 | 2026-11-01 | uninitialized memory disclosure vulnerability in pcx_decode_frame() in libavcodec/pcx.c |
| CVE-2026-120245 | 2026-11-01 | uninitialized memory disclosure vulnerability in sunrast_decode_frame() in libavcodec/sunrast.c |
| CVE-2026-120246 | 2026-11-01 | use of uninitialized variable vulnerability in the CDXL decoder |
| CVE-2026-120247 | 2026-11-01 | use of uninitialized resource vulnerability in the Huffyuv decoder |
| CVE-2026-125064 | 2026-11-09 | NULL pointer dereference vulnerability in g726_decode_frame() in libavcodec/g726.c because it ignores init_get |
| CVE-2026-125065 | 2026-11-09 | NULL pointer dereference vulnerability in tgv_decode_inter() in libavcodec/eatgv.c |
| CVE-2026-125066 | 2026-11-09 | NULL pointer dereference vulnerability in the Cirrus Logic AccuPak (CLJR) decoder in libavcodec/cljrdec.c beca |
| CVE-2026-125067 | 2026-11-09 | NULL pointer dereference vulnerability in vble_decode_frame() in libavcodec/vble.c because it ignores init_get |
| CVE-2026-125068 | 2026-11-09 | NULL pointer dereference vulnerability in the Bink video decoder because decode_frame() in libavcodec/bink.c i |
| CVE-2026-125069 | 2026-11-09 | NULL pointer dereference vulnerability in the Motion Pixels decoder because mp_decode_frame() ignores init_get |
| CVE-2026-125070 | 2026-11-09 | NULL pointer dereference vulnerability in tqi_decode_frame() in libavcodec/eatqi.c, |
| CVE-2026-125071 | 2026-11-09 | NULL pointer dereference vulnerability in libavcodec/jvdec.c |
| CVE-2026-125072 | 2026-11-09 | NULL pointer dereference vulnerability in mp_decode_frame() in libavcodec/mpegaudiodec_template.c because init |
| CVE-2026-125073 | 2026-11-09 | infinite loop vulnerability in bit_allocation() in libavcodec/imc.c |
| CVE-2026-125095 | 2026-11-09 | uninitialized memory use vulnerability in the C93 video decoder in libavcodec/c93.c, where decode_frame() neve |
| CVE-2026-125096 | 2026-11-09 | uninitialized memory disclosure vulnerability in libavcodec/tiertexseqv.c |
| CVE-2026-125097 | 2026-11-09 | uninitialized memory disclosure vulnerability in raw_decode() in libavcodec/rawdec.c |
| CVE-2026-125098 | 2026-11-09 | information disclosure vulnerability in vp8_lossy_decode_alpha() in libavcodec/webp.c |
| CVE-2026-125099 | 2026-11-09 | uninitialized memory disclosure vulnerability in the GEM raster image decoder in libavcodec/gemdec.c |
| CVE-2026-125100 | 2026-11-09 | integer overflow vulnerability in the OpenEXR decoder's decode_frame() in libavcodec/exr.c |
| CVE-2026-125101 | 2026-11-09 | information disclosure vulnerability in the VMnc decoder in libavcodec/vmnc.c |
| CVE-2026-125102 | 2026-11-09 | uninitialized memory disclosure vulnerability in tak_decode_frame() in libavcodec/takdec.c |
| CVE-2026-125103 | 2026-11-09 | information disclosure vulnerability in ff_mlz_decompression() in libavcodec/mlz.c, |
| CVE-2026-125104 | 2026-11-09 | memory exhaustion vulnerability in ape_decode_frame() in libavcodec/apedec.c |
| CVE-2026-125170 | 2026-11-09 | uninitialized memory disclosure vulnerability in targa_decode_rle() in libavcodec/targa.c caused by missing pa |
| CVE-2026-125171 | 2026-11-09 | out-of-bounds read vulnerability in the Musepack SV7 decoder because mpc7_decode_init() does not validate last |
| CVE-2026-125172 | 2026-11-09 | out-of-bounds read vulnerability in libxevd_receive_frame() in libavcodec/libxevd.c *(not in this build)* |
| CVE-2026-125173 | 2026-11-09 | memory leak vulnerability in libxevd_receive_frame() in libavcodec/libxevd.c *(not in this build)* |
| CVE-2026-125175 | 2026-11-09 | information disclosure vulnerability in flashsv_decode_block() in libavcodec/flashsv.c |
| CVE-2026-125176 | 2026-11-09 | uninitialized memory read vulnerability in decode_hybrid() in libavcodec/flashsv.c |
| CVE-2026-125177 | 2026-11-09 | information disclosure vulnerability in the MSCC/SRGC decoder in libavcodec/mscc.c |
| CVE-2026-125178 | 2026-11-09 | out-of-bounds heap read vulnerability in tdsc_load_cursor() in libavcodec/tdsc.c, |
| CVE-2026-125179 | 2026-11-09 | uninitialized memory vulnerability in the VQA video decoder in libavcodec/vqavideo.c |
| CVE-2026-125180 | 2026-11-09 | memory exhaustion vulnerability in the libavcodec/exif.c parser |
| CVE-2026-125181 | 2026-11-09 | out-of-bounds write vulnerability in flic_decode_frame_15_16BPP() in libavcodec/flicvideo.c |
| CVE-2026-125182 | 2026-11-09 | out-of-bounds read vulnerability in the Cook decoder joint_decode() function because cook_decode_init() does n |
| CVE-2026-125183 | 2026-11-09 | denial of service vulnerability in pps_3d_extension() in libavcodec/hevc/ps.c |
| CVE-2026-125184 | 2026-11-09 | information disclosure vulnerability in the CamStudio decoder (libavcodec/cscd.c) |
| CVE-2026-125185 | 2026-11-09 | division by zero vulnerability in ff_aom_parse_film_grain_sets() |
| CVE-2026-125186 | 2026-11-09 | uncontrolled resource consumption vulnerability in the dts2pts bitstream filter |
| CVE-2026-125187 | 2026-11-09 | reachable assertion vulnerability in the TTA encoder's tta_encode_frame() in libavcodec/ttaenc.c, |
| CVE-2026-125188 | 2026-11-09 | heap out-of-bounds read vulnerability in libavcodec/proresenc_anatoliy.c |
| CVE-2026-125189 | 2026-11-09 | denial of service vulnerability in the lcevc_metadata bitstream filter caused by a process block position mism |
| CVE-2026-125190 | 2026-11-09 | information disclosure vulnerability in decode_mvc2() in libavcodec/mvcdec.c |
| CVE-2026-125191 | 2026-11-09 | reference count leak in libavcodec/v4l2_buffers.c |
| CVE-2026-125192 | 2026-11-09 | uninitialized memory vulnerability in the DXA decoder in libavcodec/dxa.c |
| CVE-2026-125193 | 2026-11-09 | out-of-bounds read vulnerability in bitpacked_decode_uyvy422() in libavcodec/bitpacked_dec.c because it never  |
| CVE-2026-125194 | 2026-11-09 | out-of-bounds read vulnerability in pcm_dvd_encode_frame() in libavcodec/pcm-dvdenc.c when a 24-bit final fram |
| CVE-2026-125195 | 2026-11-09 | uninitialized memory disclosure vulnerability in adpcm_encode_frame() in libavcodec/adpcmenc.c |
| CVE-2026-125196 | 2026-11-09 | heap buffer overflow vulnerability in liboapve_encode() in libavcodec/liboapvenc.c |
| CVE-2026-125197 | 2026-11-09 | integer underflow in decode_frame() in libavcodec/lcldec.c |
| CVE-2026-125198 | 2026-11-09 | memory leak vulnerability in mediaformat_jni_setBuffer() in libavcodec/mediacodec_wrapper.c *(not in this build)* |
| CVE-2026-125199 | 2026-11-09 | memory leak vulnerability in vc1_decode_frame() in libavcodec/vc1dec.c |
| CVE-2026-125200 | 2026-11-09 | memory leak vulnerability in libavcodec/libx265.c because libx265_encode_frame() never frees the rpu.payload a |
| CVE-2026-125202 | 2026-11-09 | heap buffer overflow vulnerability in vaapi_hevc_start_frame() in libavcodec/vaapi_hevc.c |
| CVE-2026-125204 | 2026-11-09 | heap buffer overflow in ff_libwebp_get_frame() in libwebpenc_common.c |
| CVE-2026-125205 | 2026-11-09 | unbounded memory allocation vulnerability in the av1_frame_merge bitstream filter |
| CVE-2026-125206 | 2026-11-09 | out-of-bounds read vulnerability in the prores_ks encoder's get_alpha_data() |
| CVE-2026-125207 | 2026-11-09 | uncontrolled memory allocation vulnerability in the Interplay ACM decoder |
| CVE-2026-125208 | 2026-11-09 | out-of-bounds write vulnerability in v4l2_buffer_swframe_to_buf() in libavcodec/v4l2_buffers.c because cumulat |
| CVE-2026-125210 | 2026-11-09 | heap buffer overflow vulnerability in aribcaption_trans_text_subtitle() in libavcodec/libaribcaption.c when de *(not in this build)* |
| CVE-2026-125211 | 2026-11-09 | out-of-bounds read and invalid free vulnerability in aribcaption_trans_ass_subtitle() in libavcodec/libaribcap *(not in this build)* |
| CVE-2026-125212 | 2026-11-09 | heap buffer overflow vulnerability in libavcodec/videotoolboxenc.c |
| CVE-2026-125213 | 2026-11-09 | heap buffer overflow vulnerability in the PSD decoder in libavcodec/psd.c |
| CVE-2026-125214 | 2026-11-09 | heap buffer overflow vulnerability in pcm_bluray_decode_frame() in libavcodec/pcm-bluray.c on big-endian hosts |
| CVE-2026-125215 | 2026-11-09 | NULL pointer dereference vulnerability in ff_dovi_rpu_generate() in libavcodec/dovi_rpuenc.c |
| CVE-2026-125216 | 2026-11-09 | NULL pointer dereference vulnerability in libavcodec/dpxenc.c |
| CVE-2026-125217 | 2026-11-09 | uninitialized memory use vulnerability in roq_dpcm_encode_frame() in libavcodec/roqaudioenc.c |
| CVE-2026-125218 | 2026-11-09 | heap buffer overflow vulnerability in the APNG encoder's encode_apng() function in libavcodec/pngenc.c when fr |
| CVE-2026-125219 | 2026-11-09 | heap buffer overflow vulnerability in vdpau_hevc_start_frame() in libavcodec/vdpau_hevc.c *(not in this build)* |
| CVE-2026-125220 | 2026-11-09 | deadlock vulnerability in mimic_decode_frame() in libavcodec/mimic.c |
| CVE-2026-125221 | 2026-11-09 | uncontrolled recursion vulnerability in score_header() in libavcodec/flac_parser.c |
| CVE-2026-125222 | 2026-11-09 | integer overflow vulnerability in hap_parse_frame_header() in libavcodec/hapdec.c |
| CVE-2026-125223 | 2026-11-09 | memory leak vulnerability in the VP9 decoder |
| CVE-2026-125224 | 2026-11-09 | denial of service vulnerability in libavcodec/vorbis_parser.c |
| CVE-2026-125225 | 2026-11-09 | NULL pointer dereference vulnerability in aac_adtstoasc_filter() |
| CVE-2026-125226 | 2026-11-09 | uncontrolled memory allocation vulnerability in sbg_read_header() in libavformat/sbgdec.c |
| CVE-2026-125227 | 2026-11-09 | integer overflow in cbs_jpeg_write_scan() in libavcodec/cbs_jpeg.c |
| CVE-2026-125229 | 2026-11-09 | out-of-bounds memory access vulnerability in the encode_frame() function of libavcodec/huffyuvenc.c, because e |
| CVE-2026-125230 | 2026-11-09 | integer overflow vulnerability in the pcm_rechunk bitstream filter |
| CVE-2026-125231 | 2026-11-09 | NULL pointer dereference vulnerability in libavcodec/adxdec.c because adx_decode_header() updates the channel  |
| CVE-2026-125232 | 2026-11-09 | division by zero vulnerability in estimate_motion_b() in libavcodec/motion_est.c, caused by frame timestamp di |
| CVE-2026-125233 | 2026-11-09 | heap buffer overflow vulnerability in dvbsub_encode() in libavcodec/dvbsubenc.c |
| CVE-2026-125234 | 2026-11-09 | integer overflow vulnerability in wavpack_encode_init() in libavcodec/wavpackenc.c |
| CVE-2026-125235 | 2026-11-09 | heap overflow vulnerability in libavcodec/qsvenc.c |
| CVE-2026-125236 | 2026-11-09 | memory leak vulnerability in alloc_frame() in libavcodec/vvc/refs.c |
| CVE-2026-125237 | 2026-11-09 | denial of service vulnerability in libavcodec/dpx.c |
| CVE-2026-125238 | 2026-11-09 | reachable assertion vulnerability in libxevd_receive_frame() in libavcodec/libxevd.c *(not in this build)* |
| CVE-2026-125239 | 2026-11-09 | heap buffer overflow vulnerability in ff_dxva2_hevc_fill_picture_parameters() |
| CVE-2026-125240 | 2026-11-09 | resource leak vulnerability in svt_jpegxs_dec_decode() in libsvtjpegxsdec.c |
| CVE-2026-125241 | 2026-11-09 | heap buffer overflow vulnerability in libavcodec/flicvideo.c |
| CVE-2026-125242 | 2026-11-09 | memory leak vulnerability in libavcodec/vdpau.c *(not in this build)* |
| CVE-2026-125243 | 2026-11-09 | uninitialized memory disclosure vulnerability in ff_jpegls_decode_picture() in libavcodec/jpeglsdec.c, |
| CVE-2026-125245 | 2026-11-09 | memory leak vulnerability in ff_mjpeg_decode_sof() in libavcodec/mjpegdec.c, |
| CVE-2026-125246 | 2026-11-09 | denial of service vulnerability in cbs_jpeg_assemble_fragment() |
| CVE-2026-125247 | 2026-11-09 | integer overflow vulnerability in dng_decode_tiles() |
| CVE-2026-125248 | 2026-11-09 | integer overflow vulnerability in libavcodec/ffv1enc_vulkan.c |
| CVE-2026-125249 | 2026-11-09 | integer overflow in ff_vk_decode_add_slice() in libavcodec/vulkan_decode.c |
| CVE-2026-125250 | 2026-11-09 | heap buffer overflow in the GIF encoder's gif_image_write_image() in libavcodec/gif.c because shrunk_buf is si |
| CVE-2026-125251 | 2026-11-09 | integer overflow vulnerability in the VVC decoder alloc_frame() function in libavcodec/vvc/refs.c |
| CVE-2026-125252 | 2026-11-09 | memory leak vulnerability in libavcodec/vaapi_decode.c |
| CVE-2026-125253 | 2026-11-09 | integer overflow in cbs_vp9_split_fragment() in libavcodec/cbs_vp9.c |
| CVE-2026-125254 | 2026-11-09 | division by zero vulnerability in the VVC decoder because ff_vvc_slice_rpl() fails to validate num_ref_idx_act |
| CVE-2026-125255 | 2026-11-09 | use after free vulnerability in libavcodec/mjpegdec.c |
| CVE-2026-125256 | 2026-11-09 | heap buffer overflow vulnerability in ff_llvidenc_diff_bytes_rvv() *(not in this build)* |
| CVE-2026-125257 | 2026-11-09 | off-by-one heap overflow vulnerability in get_exponent_dynamic() in libavcodec/nellymoserenc.c |
| CVE-2026-125258 | 2026-11-09 | division by zero vulnerability in dovi_configure_ext() in libavcodec/dovi_rpuenc.c |
| CVE-2026-125259 | 2026-11-09 | integer overflow vulnerability in ff_prores_kostya_encode_init() |
| CVE-2026-125260 | 2026-11-09 | heap buffer overflow vulnerability in libavcodec/exrenc.c |
| CVE-2026-125261 | 2026-11-09 | out-of-bounds read vulnerability in the SGI encoder's encode_frame() in libavcodec/sgienc.c, where unsigned si |
| CVE-2026-125262 | 2026-11-09 | heap buffer overflow vulnerability in libavcodec/lcevcdec.c because LCEVC output picture dimensions are not va *(not in this build)* |
| CVE-2026-125263 | 2026-11-09 | FFmpeg 9.0 through 9.0.2 built with liblcevc_dec fails to validate LCEVC enhanced output dimensions against ma *(not in this build)* |
| CVE-2026-125264 | 2026-11-09 | uncontrolled resource consumption vulnerability in parse_frame_header() in libavcodec/jpegxl_parser.c |
| CVE-2026-125265 | 2026-11-09 | use-after-free vulnerability in libavcodec/nvdec.c because ff_nvdec_start_frame() fails to reset ctx->bitstrea |
| CVE-2026-125266 | 2026-11-09 | uninitialized stack memory disclosure vulnerability in old_codec23() of libavcodec/sanm.c |
| CVE-2026-125268 | 2026-11-09 | uninitialized memory disclosure vulnerability in the CineForm HD decoder |
| CVE-2026-125269 | 2026-11-09 | double free vulnerability in libavcodec/cbs_sei.c where cbs_sei_delete_message() leaves a stale extension_data |
| CVE-2026-125270 | 2026-11-09 | heap out-of-bounds read vulnerability in v4l2_buffer_swframe_to_buf() in libavcodec/v4l2_buffers.c |

## Other libraries

| library (version built) | CVEs | note |
|---|---|---|
| OpenSSL 4.0.3 | CVE-2026-88822, CVE-2026-88823, CVE-2026-95691, CVE-2026-95692, CVE-2026-107496 | published 2026-11-10; fixed in 4.0.4 / 4.1.1, which are not tagged yet |
| openjpeg 2.5.4 | CVE-2026-6192, CVE-2026-107080 | encoder side; 2.5.4 is the newest release |
| libbluray 1.4.1 | CVE-2026-112282, CVE-2026-112283 | "through 1.5.1", the newest release |
| libdvdnav 7.0.0 | CVE-2026-112058 | "through 7.0.0", the newest release |
| gdk-pixbuf 2.44.8 | CVE-2026-81893, CVE-2026-16768, CVE-2026-18090 | the fix commit of the first is in no release; FFmpeg's librsvg decoder does not call the pixbuf loaders |
| expat 2.10.0 | CVE-2026-124317 | "through 2.10.0", the newest release; Windows x64 only, probably not linked |
| giflib 6.1.3 | CVE-2026-26740 | fixed only in the repository head; giflib is not linked into the ffmpeg binary |
| glib 2.88.4 | CVE-2026-86469 | no fixed release |
| libass 0.17.5 | CVE-2026-95127 | reported against 0.17.5, the newest release |
| libva 2.23.0 | CVE-2026-56438 | "all versions" |
| cairo 1.18.4 | CVE-2025-50422 | "through 1.18.4"; the 1.18.6 notes do not mention it |
| libtiff 4.7.2 | CVE-2026-52492 | in the rgb2ycbcr tool, which is not shipped |

## Not counted here

- whisper.cpp CVE-2026-17512 and CVE-2026-17513 name a development snapshot,
  so whether 1.9.1 is in range cannot be told from the records.
- Advisories in the Rust crates librsvg and rav1e lock (bytes, time,
  tracing-subscriber): which of those crates end up in the static libraries
  was not determined.
