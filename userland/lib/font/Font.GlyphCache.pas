{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  The glyph cache: rendered outline glyphs kept, so text drawn again
  (every repaint) is only blended, not rasterized.

  A glyph is known by its font, the pixel size, the glyph, the subpixel
  offset of the pen (in quarters of a pixel) and whether it was hinted.
  The cache holds at most a number of glyphs and of coverage bytes;
  past either, the glyph used longest ago goes (least recently used).
  Glyphs are found through a hash table; the order of use is a list
  through the entries, both by index into one array.

  A bitmap handed out stays valid until the cache is next asked for a
  glyph (which may push it out). The cache is the process's, for its
  one thread that draws text.
}
unit Font.GlyphCache;

{$mode objfpc}
{$H+}

interface

uses
  Font.Outlines;

const
  SubpixelSteps = 4;
  DefaultCachedGlyphs = 2048;
  DefaultCachedBytes = 2 * 1024 * 1024;

{ The rendered glyph (rendered now if it is not in the cache). Subpixel
  is 0 to SubpixelSteps - 1. Nil only if the glyph cannot be rendered. }
function CachedGlyph(Font: TOutlineFont; PixelSize: LongInt; Glyph: LongWord; Subpixel: LongInt;
  Hinted: Boolean): PGlyphBitmap;
{ The limits (at least one glyph); glyphs past them go at once. }
procedure SetGlyphCacheLimits(Glyphs, Bytes: LongInt);
{ What the cache holds now. }
function CachedGlyphCount: LongInt;
function CachedGlyphBytes: Int64;
{ How many lookups found their glyph, and how many rendered it. }
function GlyphCacheHits: Int64;
function GlyphCacheMisses: Int64;
{ Empties the cache (and forgets the counts). }
procedure ClearGlyphCache;
{ Drops every glyph of Font (before it is freed). }
procedure ForgetFontGlyphs(Font: TOutlineFont);

implementation

uses
  Font.GlyphRendering;

const
  NoEntry = -1;
  BucketCount = 4096;

type
  TCacheEntry = record
    Font: TOutlineFont;
    PixelSize: LongInt;
    Glyph: LongWord;
    Subpixel: LongInt;
    Hinted: Boolean;
    Bitmap: TGlyphBitmap;
    Bytes: LongInt;
    { The chain of its hash bucket, and the order of use (Newer towards
      the most recently used). }
    NextInBucket: LongInt;
    Newer: LongInt;
    Older: LongInt;
  end;

var
  Entries: array of TCacheEntry;
  EntryCount: LongInt = 0;
  FreeEntries: array of LongInt;
  FreeCount: LongInt = 0;
  Buckets: array of LongInt;
  NewestEntry: LongInt = NoEntry;
  OldestEntry: LongInt = NoEntry;
  HeldGlyphs: LongInt = 0;
  HeldBytes: Int64 = 0;
  GlyphLimit: LongInt = DefaultCachedGlyphs;
  ByteLimit: Int64 = DefaultCachedBytes;
  Hits: Int64 = 0;
  Misses: Int64 = 0;

function BucketOf(Font: TOutlineFont; PixelSize: LongInt; Glyph: LongWord; Subpixel: LongInt;
  Hinted: Boolean): LongInt;
var
  Hash: QWord;
begin
  Hash := QWord(PtrUInt(Font)) shr 4;
  Hash := Hash * 31 + QWord(PixelSize);
  Hash := Hash * 31 + Glyph;
  Hash := Hash * 4 + QWord(Subpixel);
  Hash := Hash * 2 + QWord(Ord(Hinted));
  Hash := (Hash xor (Hash shr 17)) * QWord($9E3779B1);
  Result := LongInt((Hash shr 16) and (BucketCount - 1));
end;

procedure EnsureBuckets;
var
  Index: LongInt;
begin
  if Length(Buckets) = BucketCount then
    Exit;
  SetLength(Buckets, BucketCount);
  for Index := 0 to BucketCount - 1 do
    Buckets[Index] := NoEntry;
end;

{ --- The order of use -------------------------------------------------- }

procedure Unlink(Index: LongInt);
begin
  if Entries[Index].Newer <> NoEntry then
    Entries[Entries[Index].Newer].Older := Entries[Index].Older
  else
    NewestEntry := Entries[Index].Older;
  if Entries[Index].Older <> NoEntry then
    Entries[Entries[Index].Older].Newer := Entries[Index].Newer
  else
    OldestEntry := Entries[Index].Newer;
  Entries[Index].Newer := NoEntry;
  Entries[Index].Older := NoEntry;
end;

procedure LinkAsNewest(Index: LongInt);
begin
  Entries[Index].Newer := NoEntry;
  Entries[Index].Older := NewestEntry;
  if NewestEntry <> NoEntry then
    Entries[NewestEntry].Newer := Index;
  NewestEntry := Index;
  if OldestEntry = NoEntry then
    OldestEntry := Index;
end;

{ --- Entries ----------------------------------------------------------- }

procedure RemoveEntry(Index: LongInt);
var
  Bucket: LongInt;
  Cursor: LongInt;
  Previous: LongInt;
begin
  Bucket := BucketOf(Entries[Index].Font, Entries[Index].PixelSize, Entries[Index].Glyph, Entries[Index].Subpixel,
    Entries[Index].Hinted);
  Previous := NoEntry;
  Cursor := Buckets[Bucket];
  while (Cursor <> NoEntry) and (Cursor <> Index) do
  begin
    Previous := Cursor;
    Cursor := Entries[Cursor].NextInBucket;
  end;
  if Cursor = Index then
  begin
    if Previous = NoEntry then
      Buckets[Bucket] := Entries[Index].NextInBucket
    else
      Entries[Previous].NextInBucket := Entries[Index].NextInBucket;
  end;
  Unlink(Index);
  Dec(HeldGlyphs);
  HeldBytes := HeldBytes - Entries[Index].Bytes;
  Entries[Index].Font := nil;
  Entries[Index].Bitmap.Coverage := nil;
  Entries[Index].Bitmap.Colors := nil;
  if FreeCount = Length(FreeEntries) then
    SetLength(FreeEntries, 2 * FreeCount + 64);
  FreeEntries[FreeCount] := Index;
  Inc(FreeCount);
end;

{ Removes the oldest glyphs until the cache is within its limits, with
  room for one more of Incoming bytes. }
procedure MakeRoom(Incoming: LongInt);
begin
  while (OldestEntry <> NoEntry) and ((HeldGlyphs + 1 > GlyphLimit) or (HeldBytes + Incoming > ByteLimit)) do
    RemoveEntry(OldestEntry);
end;

function NewEntry: LongInt;
begin
  if FreeCount > 0 then
  begin
    Dec(FreeCount);
    Exit(FreeEntries[FreeCount]);
  end;
  if EntryCount = Length(Entries) then
    SetLength(Entries, 2 * EntryCount + 64);
  Result := EntryCount;
  Inc(EntryCount);
end;

function CachedGlyph(Font: TOutlineFont; PixelSize: LongInt; Glyph: LongWord; Subpixel: LongInt;
  Hinted: Boolean): PGlyphBitmap;
var
  Bucket: LongInt;
  Cursor: LongInt;
  Bitmap: TGlyphBitmap;
  Index: LongInt;
begin
  Result := nil;
  if (Font = nil) or (Subpixel < 0) or (Subpixel >= SubpixelSteps) then
    Exit;
  EnsureBuckets;
  Bucket := BucketOf(Font, PixelSize, Glyph, Subpixel, Hinted);
  Cursor := Buckets[Bucket];
  while Cursor <> NoEntry do
  begin
    if (Entries[Cursor].Font = Font) and (Entries[Cursor].PixelSize = PixelSize) and
       (Entries[Cursor].Glyph = Glyph) and (Entries[Cursor].Subpixel = Subpixel) and
       (Entries[Cursor].Hinted = Hinted) then
    begin
      Inc(Hits);
      Unlink(Cursor);
      LinkAsNewest(Cursor);
      Exit(@Entries[Cursor].Bitmap);
    end;
    Cursor := Entries[Cursor].NextInBucket;
  end;
  Inc(Misses);
  if not RenderGlyph(Font, Glyph, PixelSize, Subpixel / SubpixelSteps, Hinted, Bitmap) then
    Exit;
  MakeRoom(Length(Bitmap.Coverage) + 4 * Length(Bitmap.Colors));
  Index := NewEntry;
  Entries[Index].Font := Font;
  Entries[Index].PixelSize := PixelSize;
  Entries[Index].Glyph := Glyph;
  Entries[Index].Subpixel := Subpixel;
  Entries[Index].Hinted := Hinted;
  Entries[Index].Bitmap := Bitmap;
  Entries[Index].Bytes := Length(Bitmap.Coverage) + 4 * Length(Bitmap.Colors);
  Entries[Index].NextInBucket := Buckets[Bucket];
  Buckets[Bucket] := Index;
  LinkAsNewest(Index);
  Inc(HeldGlyphs);
  HeldBytes := HeldBytes + Entries[Index].Bytes;
  Result := @Entries[Index].Bitmap;
end;

procedure SetGlyphCacheLimits(Glyphs, Bytes: LongInt);
begin
  if Glyphs < 1 then
    Glyphs := 1;
  if Bytes < 0 then
    Bytes := 0;
  GlyphLimit := Glyphs;
  ByteLimit := Bytes;
  while (OldestEntry <> NoEntry) and ((HeldGlyphs > GlyphLimit) or (HeldBytes > ByteLimit)) do
    RemoveEntry(OldestEntry);
end;

function CachedGlyphCount: LongInt;
begin
  Result := HeldGlyphs;
end;

function CachedGlyphBytes: Int64;
begin
  Result := HeldBytes;
end;

function GlyphCacheHits: Int64;
begin
  Result := Hits;
end;

function GlyphCacheMisses: Int64;
begin
  Result := Misses;
end;

procedure ClearGlyphCache;
begin
  while OldestEntry <> NoEntry do
    RemoveEntry(OldestEntry);
  Hits := 0;
  Misses := 0;
end;

procedure ForgetFontGlyphs(Font: TOutlineFont);
var
  Index: LongInt;
begin
  for Index := 0 to EntryCount - 1 do
    if Entries[Index].Font = Font then
      RemoveEntry(Index);
end;

end.
