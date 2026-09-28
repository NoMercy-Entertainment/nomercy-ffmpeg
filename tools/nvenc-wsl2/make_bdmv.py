#!/usr/bin/env python3
"""Author a minimal, real BDMV disc structure so the 'bluray' protocol has
something genuine to open (not a fixture-less registration check). Field
layout taken directly from libbluray's src/libbluray/bdnav/*.c parsers
(index_parse.c, mobj_parse.c, mpls_parse.c, clpi_parse.c)."""
import struct, sys, os

def u32(v): return struct.pack(">I", v)
def u16(v): return struct.pack(">H", v)
def u8(v): return struct.pack(">B", v)

def pad(b, n):
    assert len(b) <= n, (len(b), n)
    return b + b"\x00" * (n - len(b))

class BitWriter:
    """MSB-first bit writer matching libbluray's BITSTREAM reader."""
    def __init__(self):
        self.bits = []
    def write(self, value, nbits):
        for i in range(nbits - 1, -1, -1):
            self.bits.append((value >> i) & 1)
    def bytes(self):
        assert len(self.bits) % 8 == 0, len(self.bits)
        out = bytearray()
        for i in range(0, len(self.bits), 8):
            b = 0
            for bit in self.bits[i:i+8]:
                b = (b << 1) | bit
            out.append(b)
        return bytes(out)

# ---------------------------------------------------------------- index.bdmv
def build_index():
    # app_info block content (34 bytes, fixed offset 40)
    flags = 0  # skip(1)+initial_output_mode(1)+content_exist(1)+skip(1)+dyn_range(4)+video_format(4)+frame_rate(4) = 16 bits
    app_info_content = u16(flags) + b"\x00" * 32
    assert len(app_info_content) == 34
    app_info_block = u32(34) + app_info_content

    def playback_obj_hdmv(id_ref):
        # object_type(2)+reserved(30) = 4 bytes; then hdmv: playback_type(2)+res(14)+id_ref(16)+res(32)
        b1 = struct.pack(">I", (1 << 30))  # object_type=1 (hdmv) in top 2 bits, rest reserved 0
        b2 = struct.pack(">HHI", 0, id_ref, 0)  # playback_type(2)+res(14) packed as 0x0000 (playback_type=0), id_ref, reserved32
        # b2 above: first u16=playback_type<<14 | reserved -> playback_type=0 fits as 0x0000
        return b1 + b2

    first_play = playback_obj_hdmv(0x0000)
    top_menu = playback_obj_hdmv(0xFFFF)
    index_content = first_play + top_menu + u16(0)  # num_titles = 0
    index_block = u32(len(index_content)) + index_content

    header = b"INDX" + b"0200"
    index_start = 40 + len(app_info_block)  # = 78
    ext_start = 0
    header += u32(index_start) + u32(ext_start)
    pre = pad(header, 40)
    out = pre + app_info_block
    assert len(out) == index_start, (len(out), index_start)
    out += index_block
    return out

# ------------------------------------------------------------ MovieObject.bdmv
def build_mobj():
    header = b"MOBJ" + b"0200" + u32(0)  # ext_data_start = 0
    pre = pad(header, 40)
    # one object, num_cmds = 0 (empty, valid per _mobj_parse_object)
    obj = struct.pack(">H", 0) + u16(0)  # flags(3 bits)+padding(13)=16 bits all 0, num_cmds=0
    content = u32(0) + u16(1) + obj  # reserved(32) + num_objects(16) + object[0]
    data_len = len(content) - 0
    # data_len covers everything AFTER the data_len field itself
    body = u32(len(content)) + content
    out = pre + body
    return out

# ------------------------------------------------------------------ mpls
def build_mpls():
    # AppInfoPlayList (18-byte block: 4-byte len + 14 content)
    ai_content = u8(0) + u8(1) + u16(0) + (b"\x00" * 8) + u8(0) + u8(0)
    # reserved(8)+playback_type(8)=1+ (playback_count/reserved 16)=0 + UO_mask(8 bytes) + flags(1byte,0) + reserved(1byte pad to align)
    assert len(ai_content) == 14, len(ai_content)
    ai_block = u32(14) + ai_content
    assert len(ai_block) == 18

    header_fixed = b"MPLS" + b"0200"  # 8 bytes
    list_pos = 40 + len(ai_block)  # 58

    # PlayItem
    clip_id = b"00000"
    codec_id = b"M2TS"
    flags16 = 0x0001  # reserved(11)=0, is_multi_angle(1)=0, connection_condition(4)=1
    stc_id = 0
    in_time = 0
    # ffmpeg's bluray protocol (libavformat/bluray.c) filters titles with
    # bd_get_titles(TITLES_RELEVANT, 180) -- playlists under 3 real minutes
    # are invisible to it. libbluray computes duration purely from
    # out_time - in_time (navigation.c: "duration += pi->out_time -
    # pi->in_time"), in 90kHz units, independent of the actual stream
    # length -- so this can safely exceed the short test clip underneath.
    out_time = 185 * 90000
    uo_mask = b"\x00" * 8
    ra_flag_reserved = 0x00  # random_access_flag(1)+reserved(7)
    still_mode = 0x00
    still_reserved = u16(0)
    # STN table: len(2) + reserved(2) + 8 counts(all 0) + reserved(4) = content 14 bytes after len field
    stn_content = u16(0) + (u8(0) * 8) + u32(0)
    stn_block = u16(14) + stn_content
    assert len(stn_block) == 16, len(stn_block)

    pi_content = (clip_id + codec_id + u16(flags16) + u8(stc_id) +
                  u32(in_time) + u32(out_time) + uo_mask +
                  u8(ra_flag_reserved) + u8(still_mode) + still_reserved +
                  stn_block)
    assert len(pi_content) == 48, len(pi_content)
    pi_block = u16(len(pi_content)) + pi_content
    assert len(pi_block) == 50

    playlist_content = u16(0) + u16(1) + u16(0) + pi_block  # reserved,list_count=1,sub_count=0
    playlist_block = u32(len(playlist_content)) + playlist_content

    mark_pos = list_pos + len(playlist_block)
    mark_content = u16(0)  # mark_count = 0
    mark_block = u32(len(mark_content)) + mark_content

    header = header_fixed + u32(list_pos) + u32(mark_pos) + u32(0) + (b"\x00" * 20) + ai_block
    assert len(header) == list_pos, (len(header), list_pos)
    out = header + playlist_block
    assert len(out) == mark_pos, (len(out), mark_pos)
    out += mark_block
    return out

# ------------------------------------------------------------------ clpi
def build_clpi(num_source_packets):
    clipinfo_content = (u16(0) + u8(1) + u8(1) +  # reserved16, clip_stream_type=1, application_type=1
                         u32(0) +                  # reserved31 + is_atc_delta(0)
                         u32(0x177) +               # ts_recording_rate (arbitrary, non-zero)
                         u32(num_source_packets) +
                         (b"\x00" * 128) +
                         u16(0))                    # ts_type_info len = 0
    clipinfo_block = u32(len(clipinfo_content)) + clipinfo_content
    assert len(clipinfo_content) == 146, len(clipinfo_content)

    seq_atc = u32(0) + u8(1) + u8(0)  # spn_atc_start=0, num_stc_seq=1, offset_stc_id=0
    seq_stc = u16(0) + u32(0) + u32(0) + u32(0)  # pcr_pid, spn_stc_start, pres_start, pres_end
    seq_body = u8(1) + seq_atc + seq_stc  # num_atc_seq=1, then entries
    seq_block = u32(22) + u8(0) + seq_body  # len field(=22, unchecked) + reserved(1 byte) + body

    prog_body = u8(0)  # num_prog = 0
    prog_block = u32(6) + u8(0) + prog_body  # len(unchecked)+reserved(1)+num_prog(1) => header uses skip(5*8) = len4+reserved1

    # A len==0 CPI ("no EP map") parses fine but crashes libbluray's bd_seek
    # later (verified: segfaults identically on the pre-existing static
    # v1.0.42 reference binary too -- not a regression from this change, but
    # it blocks proving the protocol actually demuxes). One coarse + one
    # fine EP map entry, all pointing at source packet 0, is enough for
    # bd_seek to have real data to resolve against instead of an empty table.
    bw = BitWriter()
    bw.write(0, 12)           # reserved
    bw.write(1, 4)            # cpi->type
    # ep_map_pos = position right here (cpi_start_addr + 6)
    bw.write(0, 8)            # reserved byte
    bw.write(1, 8)            # num_stream_pid = 1
    # EP map stream entry header (12 bytes / 96 bits, not byte-aligned per field)
    bw.write(0x1011, 16)      # pid (arbitrary, matches nothing in particular)
    bw.write(0, 10)           # reserved
    bw.write(2, 4)            # ep_stream_type (2 = video, informational only here)
    bw.write(1, 16)           # num_ep_coarse = 1
    bw.write(1, 18)           # num_ep_fine = 1
    bw.write(14, 32)          # ep_map_stream_start_addr, relative to ep_map_pos:
                               #   ep_map_pos(+6) + 14 = +20 = right after this header
    header_bytes = bw.bytes()
    assert len(header_bytes) == 2 + 2 + 12, len(header_bytes)  # (reserved+type)+(reserved+num_stream_pid)+entry

    bw2 = BitWriter()
    bw2.write(12, 32)         # fine_start, relative to this EP-map-stream's own base:
                               #   base(+20) + 12 = +32 = right after the coarse array (8 bytes)
    bw2.write(0, 18)          # coarse[0].ref_ep_fine_id = 0 (< num_ep_fine)
    bw2.write(0, 14)          # coarse[0].pts_ep = 0
    bw2.write(0, 32)          # coarse[0].spn_ep = 0 (source packet 0)
    bw2.write(0, 1)           # fine[0].is_angle_change_point
    bw2.write(0, 3)           # fine[0].i_end_position_offset
    bw2.write(0, 11)          # fine[0].pts_ep
    bw2.write(0, 17)          # fine[0].spn_ep = 0
    ep_map_stream = bw2.bytes()
    assert len(ep_map_stream) == 4 + 8 + 4, len(ep_map_stream)

    cpi_content = header_bytes + ep_map_stream
    cpi_block = u32(len(cpi_content)) + cpi_content

    seq_addr = 40 + len(clipinfo_block)
    prog_addr = seq_addr + len(seq_block)
    cpi_addr = prog_addr + len(prog_block)

    header = b"HDMV" + b"0200" + u32(seq_addr) + u32(prog_addr) + u32(cpi_addr) + u32(0) + u32(0)
    pre = pad(header, 40)
    out = pre + clipinfo_block + seq_block + prog_block + cpi_block
    return out

def to_m2ts(ts_path, m2ts_path):
    with open(ts_path, "rb") as f:
        data = f.read()
    assert len(data) % 188 == 0, "expected clean 188-byte TS packets, got %d bytes" % len(data)
    n = len(data) // 188
    out = bytearray()
    ats = 0
    for i in range(n):
        pkt = data[i*188:(i+1)*188]
        out += struct.pack(">I", ats & 0x3FFFFFFF)
        out += pkt
        ats = (ats + 6000) & 0x3FFFFFFF  # arbitrary monotonic increment
    with open(m2ts_path, "wb") as f:
        f.write(bytes(out))
    return n

def main():
    root = sys.argv[1]
    ts_path = sys.argv[2]  # pre-encoded plain mpegts (188-byte packets)
    for d in ["BDMV/PLAYLIST", "BDMV/CLIPINF", "BDMV/STREAM"]:
        os.makedirs(os.path.join(root, d), exist_ok=True)

    with open(os.path.join(root, "BDMV/index.bdmv"), "wb") as f:
        f.write(build_index())
    with open(os.path.join(root, "BDMV/MovieObject.bdmv"), "wb") as f:
        f.write(build_mobj())
    with open(os.path.join(root, "BDMV/PLAYLIST/00000.mpls"), "wb") as f:
        f.write(build_mpls())

    m2ts_path = os.path.join(root, "BDMV/STREAM/00000.m2ts")
    n = to_m2ts(ts_path, m2ts_path)

    with open(os.path.join(root, "BDMV/CLIPINF/00000.clpi"), "wb") as f:
        f.write(build_clpi(n))

    print("built disc at", root, "with", n, "source packets")

if __name__ == "__main__":
    main()
