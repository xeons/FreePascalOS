/*
 * FreePascalOS
 * Copyright (C) 2026 Brandon Scott
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * Makes a VP9 test stream whose frames change size without key frames,
 * so that they are predicted from scaled references: the host's libvpx
 * encoder, told to scale its input internally (4/5, 3/5, 1/2, back to
 * full size) every few frames. vpxenc has no option for this.
 *
 * usage: scaling-encoder INPUT.yuv WIDTH HEIGHT FRAMES OUTPUT.ivf
 * (INPUT is raw 8-bit 4:2:0)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vpx/vp8cx.h>
#include <vpx/vpx_encoder.h>

static void put16(unsigned char *p, unsigned v) {
  p[0] = v & 255;
  p[1] = (v >> 8) & 255;
}

static void put32(unsigned char *p, unsigned v) {
  put16(p, v & 0xffff);
  put16(p + 2, v >> 16);
}

static void write_header(FILE *out, int width, int height, int frames) {
  unsigned char header[32];
  memset(header, 0, sizeof(header));
  memcpy(header, "DKIF", 4);
  put16(header + 6, 32);
  memcpy(header + 8, "VP90", 4);
  put16(header + 12, width);
  put16(header + 14, height);
  put32(header + 16, 30);
  put32(header + 20, 1);
  put32(header + 24, frames);
  fwrite(header, 1, 32, out);
}

static int write_packets(vpx_codec_ctx_t *codec, FILE *out) {
  vpx_codec_iter_t iter = NULL;
  const vpx_codec_cx_pkt_t *packet;
  int count = 0;
  while ((packet = vpx_codec_get_cx_data(codec, &iter)) != NULL) {
    if (packet->kind == VPX_CODEC_CX_FRAME_PKT) {
      unsigned char header[12];
      unsigned long long pts = (unsigned long long)packet->data.frame.pts;
      put32(header, (unsigned)packet->data.frame.sz);
      put32(header + 4, (unsigned)(pts & 0xffffffffu));
      put32(header + 8, (unsigned)(pts >> 32));
      fwrite(header, 1, 12, out);
      fwrite(packet->data.frame.buf, 1, packet->data.frame.sz, out);
      count++;
    }
  }
  return count;
}

int main(int argc, char **argv) {
  vpx_codec_ctx_t codec;
  vpx_codec_enc_cfg_t cfg;
  vpx_image_t image;
  FILE *input, *output;
  int width, height, frames, frame, written = 0;
  if (argc != 6) {
    fprintf(stderr, "usage: %s INPUT.yuv WIDTH HEIGHT FRAMES OUTPUT.ivf\n", argv[0]);
    return 2;
  }
  width = atoi(argv[2]);
  height = atoi(argv[3]);
  frames = atoi(argv[4]);
  input = fopen(argv[1], "rb");
  output = fopen(argv[5], "wb");
  if (!input || !output) return 1;
  if (vpx_codec_enc_config_default(vpx_codec_vp9_cx(), &cfg, 0)) return 1;
  cfg.g_w = width;
  cfg.g_h = height;
  cfg.g_timebase.num = 1;
  cfg.g_timebase.den = 30;
  cfg.g_lag_in_frames = 0;
  cfg.g_threads = 1;
  cfg.rc_end_usage = VPX_VBR;
  cfg.rc_target_bitrate = 400;
  cfg.kf_max_dist = 1000;
  if (vpx_codec_enc_init(&codec, vpx_codec_vp9_cx(), &cfg, 0)) return 1;
  vpx_codec_control(&codec, VP8E_SET_CPUUSED, 6);
  if (!vpx_img_alloc(&image, VPX_IMG_FMT_I420, width, height, 1)) return 1;
  write_header(output, width, height, frames);
  for (frame = 0; frame < frames; frame++) {
    size_t luma = (size_t)width * height;
    size_t chroma = (size_t)((width + 1) / 2) * ((height + 1) / 2);
    int plane, row;
    for (plane = 0; plane < 3; plane++) {
      int w = plane ? (width + 1) / 2 : width;
      int h = plane ? (height + 1) / 2 : height;
      for (row = 0; row < h; row++)
        if (fread(image.planes[plane] + row * image.stride[plane], 1, w, input) != (size_t)w) return 1;
    }
    (void)luma;
    (void)chroma;
    if (frame % 8 == 4) {
      static const VPX_SCALING_MODE modes[] = { VP8E_FOURFIVE, VP8E_THREEFIVE, VP8E_ONETWO, VP8E_NORMAL };
      vpx_scaling_mode_t mode;
      mode.h_scaling_mode = modes[(frame / 8) % 4];
      mode.v_scaling_mode = modes[((frame / 8) + 1) % 4];
      vpx_codec_control(&codec, VP8E_SET_SCALEMODE, &mode);
    }
    if (vpx_codec_encode(&codec, &image, frame, 1, 0, VPX_DL_GOOD_QUALITY)) return 1;
    written += write_packets(&codec, output);
  }
  if (vpx_codec_encode(&codec, NULL, -1, 1, 0, VPX_DL_GOOD_QUALITY)) return 1;
  written += write_packets(&codec, output);
  fseek(output, 24, SEEK_SET);
  {
    unsigned char count[4];
    put32(count, written);
    fwrite(count, 1, 4, output);
  }
  fclose(output);
  fclose(input);
  vpx_img_free(&image);
  vpx_codec_destroy(&codec);
  return 0;
}
