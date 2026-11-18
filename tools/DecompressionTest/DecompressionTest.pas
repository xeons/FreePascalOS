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
  DecompressionTest - checks the whole-buffer decoders the kernel
  unpacks its RAM disk with (Compression.MemoryImages: xz/LZMA2 and
  gzip) on the host (make decompression-test), over the fixtures
  make-fixtures.py writes with Python's lzma and gzip: random, highly
  compressible, text, tiny and empty data, several blocks, padding;
  truncated streams, damaged checks and data, unsupported features.

    DecompressionTest <fixture directory> [image ...]

  Each further file is decompressed and timed (the real system image,
  say). Prints one line per check and the totals; exits with 1 if any
  failed.
}
program DecompressionTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  TestChecks,
  Compression.DecodeResults,
  Compression.MemoryImages;

var
  Workspace: TDecompressionWorkspace;

function ReadWholeFile(const Path: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function KindText(Kind: TCompressedImageKind): string;
begin
  case Kind of
    ImageXz: Result := 'xz';
    ImageGzip: Result := 'gzip';
    ImageZstandard: Result := 'zstd';
  else
    Result := 'none';
  end;
end;

function ResultText(Outcome: TDecodeResult): string;
begin
  case Outcome of
    DecodeSucceeded: Result := 'ok';
    DecodeTruncated: Result := 'truncated';
    DecodeInvalidHeader: Result := 'invalidheader';
    DecodeCorrupt: Result := 'corrupt';
    DecodeChecksumMismatch: Result := 'checksummismatch';
    DecodeSizeMismatch: Result := 'sizemismatch';
    DecodeUnsupported: Result := 'unsupported';
    DecodeOutputTooSmall: Result := 'outputtoosmall';
    DecodeTrailingData: Result := 'trailingdata';
  else
    Result := 'unknown';
  end;
end;

{ Sizes the output, then decodes; Output holds what came out. A size the
  image states beyond 1 GiB is taken as a failure. }
function DecodeImage(const Input: TBytes; Kind: TCompressedImageKind; out Output: TBytes;
  out Milliseconds: QWord): TDecodeResult;
var
  Size: QWord;
  Started: QWord;
begin
  Output := nil;
  Milliseconds := 0;
  Result := CompressedImageSize(Kind, PByte(Input), Length(Input), Size);
  if Result <> DecodeSucceeded then
    Exit;
  if Size > 1024 * 1024 * 1024 then
    Exit(DecodeOutputTooSmall);
  SetLength(Output, Size);
  Started := GetTickCount64;
  Result := DecompressImage(Workspace, Kind, PByte(Input), Length(Input), PByte(Output), Size);
  Milliseconds := GetTickCount64 - Started;
end;

function SameContents(const Left, Right: TBytes): Boolean;
begin
  Result := (Length(Left) = Length(Right)) and
    ((Length(Left) = 0) or CompareMem(@Left[0], @Right[0], Length(Left)));
end;

procedure RunCase(const Directory: string; const Fields: TStringList);
var
  Name: string;
  ExpectedKind: string;
  Expected: string;
  Input: TBytes;
  Output: TBytes;
  Original: TBytes;
  Kind: TCompressedImageKind;
  Outcome: TDecodeResult;
  Milliseconds: QWord;
begin
  Name := Fields[0];
  ExpectedKind := Fields[1];
  Expected := Fields[2];
  Input := ReadWholeFile(Directory + '/' + Name);
  Kind := DetectCompressedImage(PByte(Input), Length(Input));
  Check(KindText(Kind) = ExpectedKind, Name + ': detected as ' + ExpectedKind + ' (got ' + KindText(Kind) + ')');
  if Kind = ImageNotCompressed then
    Exit;
  Outcome := DecodeImage(Input, Kind, Output, Milliseconds);
  if Expected = 'ok' then
  begin
    Check(Outcome = DecodeSucceeded, Name + ': decodes (got ' + ResultText(Outcome) + ')');
    if Fields.Count > 3 then
    begin
      Original := ReadWholeFile(Directory + '/' + Fields[3]);
      Check(SameContents(Output, Original), Name + ': output equals ' + Fields[3]);
    end;
  end
  else if Expected = 'fail' then
    Check(Outcome <> DecodeSucceeded, Name + ': refused (got ' + ResultText(Outcome) + ')')
  else
    Check(ResultText(Outcome) = Expected, Name + ': refused as ' + Expected + ' (got ' + ResultText(Outcome) + ')');
end;

procedure RunManifest(const Directory: string);
var
  Lines: TStringList;
  Fields: TStringList;
  Line: string;
begin
  Lines := TStringList.Create;
  Fields := TStringList.Create;
  try
    Lines.LoadFromFile(Directory + '/manifest.txt');
    Fields.Delimiter := ' ';
    Fields.StrictDelimiter := True;
    for Line in Lines do
    begin
      if Trim(Line) = '' then
        Continue;
      Fields.DelimitedText := Trim(Line);
      RunCase(Directory, Fields);
    end;
  finally
    Fields.Free;
    Lines.Free;
  end;
end;

procedure TimeImage(const Path: string);
var
  Input: TBytes;
  Output: TBytes;
  Kind: TCompressedImageKind;
  Outcome: TDecodeResult;
  Milliseconds: QWord;
begin
  Input := ReadWholeFile(Path);
  Kind := DetectCompressedImage(PByte(Input), Length(Input));
  Outcome := DecodeImage(Input, Kind, Output, Milliseconds);
  Check(Outcome = DecodeSucceeded, Format('%s: %s, %d KiB -> %d KiB in %d ms (%s)',
    [Path, KindText(Kind), Length(Input) div 1024, Length(Output) div 1024, Milliseconds, ResultText(Outcome)]));
end;

var
  Index: Integer;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: DecompressionTest <fixture directory> [image ...]');
    Halt(2);
  end;
  RunManifest(ParamStr(1));
  for Index := 2 to ParamCount do
    TimeImage(ParamStr(Index));
  FinishChecks('decompression test');
end.
