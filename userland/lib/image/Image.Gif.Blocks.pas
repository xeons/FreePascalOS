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
  The pieces of a GIF file.

  'GIF87a' or 'GIF89a'; the logical screen (width, height, flags with
  a global colour table and its size, the background colour's index,
  the aspect ratio); the global colour table (three bytes a colour,
  2^(n+1) of them). Then blocks: '!' (an extension: a label and data
  sub-blocks), ',' (an image: its place and size, flags with a local
  colour table and interlacing, the table, the LZW minimum code size
  and the data as sub-blocks) and ';' (the end).

  Sub-blocks are a length byte and that many bytes, until a length of
  zero. ReadSubBlocks joins them; one that the file cuts short gives what
  there is and says so.

  The extensions read here: the graphic control extension (disposal,
  transparency, delay, for the next image), NETSCAPE2.0 and ANIMEXTS1.0
  (the loop count) and comments.
}
unit Image.Gif.Blocks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Drawing.Colors,
  Image.Errors,
  Image.ByteReaders;

const
  GifExtensionIntroducer = $21;
  GifImageSeparator = $2C;
  GifTrailer = $3B;
  GifGraphicControlLabel = $F9;
  GifCommentLabel = $FE;
  GifApplicationLabel = $FF;
  GifPlainTextLabel = $01;

type
  TGifPalette = array of TColor;

  TGifScreen = record
    Width: LongInt;
    Height: LongInt;
    BackgroundIndex: LongInt;
    GlobalPalette: TGifPalette;
    PaletteBits: LongInt;
  end;

  TGifGraphicControl = record
    Present: Boolean;
    Disposal: LongInt;
    DelayHundredths: LongInt;
    TransparentIndex: LongInt;
  end;

  TGifImageDescriptor = record
    Left: LongInt;
    Top: LongInt;
    Width: LongInt;
    Height: LongInt;
    Interlaced: Boolean;
    LocalPalette: TGifPalette;
    PaletteBits: LongInt;
  end;

{ True when Data starts with a GIF signature. }
function IsGifSignature(const Data: TBytes): Boolean;
{ The header, logical screen and global colour table. }
procedure ReadGifScreen(Reader: TImageByteReader; out Screen: TGifScreen);
function ReadGifPalette(Reader: TImageByteReader; Bits: LongInt): TGifPalette;
{ Joins sub-blocks into Output (from its start; it grows as needed) and
  returns their length; Complete is False when the file ends first. }
function ReadSubBlocks(Reader: TImageByteReader; var Output: TBytes; out Complete: Boolean): PtrInt;
procedure SkipSubBlocks(Reader: TImageByteReader);
procedure ReadGifImageDescriptor(Reader: TImageByteReader; out Descriptor: TGifImageDescriptor);
{ A graphic control extension's data (after its label). }
procedure ReadGraphicControl(Reader: TImageByteReader; out Control: TGifGraphicControl);
{ An application extension (after its label): the loop count if it is
  NETSCAPE2.0 or ANIMEXTS1.0 (LoopCount unchanged otherwise). }
procedure ReadApplicationExtension(Reader: TImageByteReader; var LoopCount: LongInt; var HasLoopCount: Boolean);
{ A comment extension's text (after its label). }
function ReadCommentExtension(Reader: TImageByteReader): string;

implementation

function IsGifSignature(const Data: TBytes): Boolean;
begin
  Result := BytesStartWith(Data, [Ord('G'), Ord('I'), Ord('F'), Ord('8'), Ord('7'), Ord('a')]) or
    BytesStartWith(Data, [Ord('G'), Ord('I'), Ord('F'), Ord('8'), Ord('9'), Ord('a')]);
end;

function ReadGifPalette(Reader: TImageByteReader; Bits: LongInt): TGifPalette;
var
  Count: LongInt;
  Index: LongInt;
  Red: Byte;
  Green: Byte;
  Blue: Byte;
begin
  Count := 1 shl Bits;
  Result := nil;
  SetLength(Result, Count);
  for Index := 0 to Count - 1 do
  begin
    Red := Reader.ReadByte;
    Green := Reader.ReadByte;
    Blue := Reader.ReadByte;
    Result[Index] := RgbColor(Red, Green, Blue);
  end;
end;

procedure ReadGifScreen(Reader: TImageByteReader; out Screen: TGifScreen);
var
  Flags: Byte;
begin
  Screen := Default(TGifScreen);
  if not IsGifSignature(Reader.Data) then
    RaiseImageError(ImageErrorMalformed, 'not a GIF file');
  Reader.Skip(6);
  Screen.Width := Reader.ReadWordLittle;
  Screen.Height := Reader.ReadWordLittle;
  Flags := Reader.ReadByte;
  Screen.BackgroundIndex := Reader.ReadByte;
  Reader.Skip(1);
  if (Flags and $80) <> 0 then
  begin
    Screen.PaletteBits := (Flags and 7) + 1;
    Screen.GlobalPalette := ReadGifPalette(Reader, Screen.PaletteBits);
  end;
end;

function ReadSubBlocks(Reader: TImageByteReader; var Output: TBytes; out Complete: Boolean): PtrInt;
var
  BlockSize: LongInt;
  Available: PtrInt;
begin
  Result := 0;
  Complete := False;
  while Reader.HasBytes(1) do
  begin
    BlockSize := Reader.ReadByte;
    if BlockSize = 0 then
    begin
      Complete := True;
      Exit;
    end;
    Available := BlockSize;
    if Available > Reader.Remaining then
      Available := Reader.Remaining;
    if Result + Available > Length(Output) then
      SetLength(Output, 2 * (Result + Available) + 256);
    if Available > 0 then
      Move(Reader.Data[Reader.Position], Output[Result], Available);
    Inc(Result, Available);
    Reader.Skip(Available);
    if Available < BlockSize then
      Exit;
  end;
end;

procedure SkipSubBlocks(Reader: TImageByteReader);
var
  BlockSize: LongInt;
begin
  repeat
    BlockSize := Reader.ReadByte;
    Reader.Skip(BlockSize);
  until BlockSize = 0;
end;

procedure ReadGifImageDescriptor(Reader: TImageByteReader; out Descriptor: TGifImageDescriptor);
var
  Flags: Byte;
begin
  Descriptor := Default(TGifImageDescriptor);
  Descriptor.Left := Reader.ReadWordLittle;
  Descriptor.Top := Reader.ReadWordLittle;
  Descriptor.Width := Reader.ReadWordLittle;
  Descriptor.Height := Reader.ReadWordLittle;
  Flags := Reader.ReadByte;
  Descriptor.Interlaced := (Flags and $40) <> 0;
  if (Flags and $80) <> 0 then
  begin
    Descriptor.PaletteBits := (Flags and 7) + 1;
    Descriptor.LocalPalette := ReadGifPalette(Reader, Descriptor.PaletteBits);
  end;
end;

procedure ReadGraphicControl(Reader: TImageByteReader; out Control: TGifGraphicControl);
var
  BlockSize: LongInt;
  Flags: Byte;
begin
  Control := Default(TGifGraphicControl);
  Control.TransparentIndex := -1;
  BlockSize := Reader.ReadByte;
  if BlockSize >= 4 then
  begin
    Flags := Reader.ReadByte;
    Control.DelayHundredths := Reader.ReadWordLittle;
    if (Flags and 1) <> 0 then
      Control.TransparentIndex := Reader.ReadByte
    else
      Reader.Skip(1);
    Control.Disposal := (Flags shr 2) and 7;
    Control.Present := True;
    Reader.Skip(BlockSize - 4);
  end
  else
    Reader.Skip(BlockSize);
  SkipSubBlocks(Reader);
end;

procedure ReadApplicationExtension(Reader: TImageByteReader; var LoopCount: LongInt; var HasLoopCount: Boolean);
var
  BlockSize: LongInt;
  Identifier: TBytes;
  Name: string;
  SubBlockSize: LongInt;
begin
  BlockSize := Reader.ReadByte;
  Identifier := Reader.ReadBytes(BlockSize);
  Name := '';
  if BlockSize = 11 then
  begin
    SetLength(Name, 11);
    Move(Identifier[0], Name[1], 11);
  end;
  if (Name = 'NETSCAPE2.0') or (Name = 'ANIMEXTS1.0') then
  begin
    repeat
      SubBlockSize := Reader.ReadByte;
      if (SubBlockSize >= 3) and (Reader.PeekByte(0) = 1) then
      begin
        Reader.Skip(1);
        LoopCount := Reader.ReadWordLittle;
        HasLoopCount := True;
        Reader.Skip(SubBlockSize - 3);
      end
      else
        Reader.Skip(SubBlockSize);
    until SubBlockSize = 0;
  end
  else
    SkipSubBlocks(Reader);
end;

function ReadCommentExtension(Reader: TImageByteReader): string;
var
  Bytes: TBytes;
  Count: PtrInt;
  Complete: Boolean;
begin
  Bytes := nil;
  Count := ReadSubBlocks(Reader, Bytes, Complete);
  Result := '';
  SetLength(Result, Count);
  if Count > 0 then
    Move(Bytes[0], Result[1], Count);
  if not Complete then
    RaiseImageError(ImageErrorTruncated, 'comment');
end;

end.
