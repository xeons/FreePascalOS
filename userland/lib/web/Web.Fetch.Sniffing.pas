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
  Content sniffing (MIME Sniffing Standard sections 6 and 7) over the
  resource header (the first 1445 bytes):

  - the MIME type sniffing algorithm for navigations and plain loads:
    an unknown or missing type is worked out from the bytes (HTML tags,
    XML, PDF, PostScript, byte order marks, image and archive
    signatures, text or binary), nosniff keeps the given type, the
    Apache text/plain bug is checked (text or binary), and a supported
    image type is checked against the image signatures;
  - sniffing in an image context (the image signatures win, XML types
    stay);
  - the binary data bytes test.
}
unit Web.Fetch.Sniffing;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  ResourceHeaderLength = 1445;

type
  TSniffOptions = record
    { The response said X-Content-Type-Options: nosniff. }
    NoSniff: Boolean;
    { The Content-Type was sent exactly as one of the Apache defaults. }
    CheckForApacheBug: Boolean;
  end;

{ The computed MIME type essence for a resource: SuppliedEssence is the
  Content-Type's essence ('' when there was none). }
function SniffMimeType(const SuppliedEssence: string; const Header: string; constref Options: TSniffOptions): string;
{ The same in an image context (img, favicons, CSS images). }
function SniffImageMimeType(const SuppliedEssence: string; const Header: string): string;
{ The image type of the signature, or ''. }
function MatchImageSignature(const Header: string): string;
{ The rules for identifying an unknown MIME type. }
function IdentifyUnknownMimeType(const Header: string; SniffScriptable: Boolean): string;
function ContainsBinaryDataBytes(const Header: string): Boolean;
{ True for the Content-Type values Apache sent by default. }
function IsApacheBugContentType(const RawContentType: string): Boolean;
function IsUnknownMimeType(const Essence: string): Boolean;

implementation

uses
  Web.Fetch.MimeTypes;

function StartsWithBytes(const Header, Pattern: string): Boolean;
begin
  Result := (Length(Header) >= Length(Pattern)) and (Copy(Header, 1, Length(Pattern)) = Pattern);
end;

function IsBinaryDataByte(Value: Byte): Boolean; inline;
begin
  Result := (Value <= $08) or (Value = $0B) or ((Value >= $0E) and (Value <= $1A)) or
    ((Value >= $1C) and (Value <= $1F));
end;

function ContainsBinaryDataBytes(const Header: string): Boolean;
var
  Index: Integer;
begin
  for Index := 1 to Length(Header) do
    if IsBinaryDataByte(Ord(Header[Index])) then
      Exit(True);
  Result := False;
end;

function IsWhitespaceByte(Character: Char): Boolean; inline;
begin
  Result := Character in [#9, #10, #12, #13, ' '];
end;

function IsTagTerminatingByte(Character: Char): Boolean; inline;
begin
  Result := Character in [' ', '>'];
end;

{ An HTML pattern: leading whitespace skipped, letters compared without
  case, then a tag-terminating byte. }
function MatchesHtmlPattern(const Header, Pattern: string): Boolean;
var
  Position, Index: Integer;
begin
  Position := 1;
  while (Position <= Length(Header)) and IsWhitespaceByte(Header[Position]) do
    Inc(Position);
  if Position + Length(Pattern) > Length(Header) then
    Exit(False);
  for Index := 1 to Length(Pattern) do
    if UpCase(Header[Position + Index - 1]) <> Pattern[Index] then
      Exit(False);
  Result := IsTagTerminatingByte(Header[Position + Length(Pattern)]);
end;

function MatchesScriptableType(const Header: string; out Essence: string): Boolean;
const
  HtmlPatterns: array[0..16] of string = ('<!DOCTYPE HTML', '<HTML', '<HEAD', '<SCRIPT', '<IFRAME', '<H1', '<DIV',
    '<FONT', '<TABLE', '<A', '<STYLE', '<TITLE', '<B', '<BODY', '<BR', '<P', '<!--');
var
  Index, Position: Integer;
begin
  for Index := Low(HtmlPatterns) to High(HtmlPatterns) do
    if MatchesHtmlPattern(Header, HtmlPatterns[Index]) then
    begin
      Essence := 'text/html';
      Exit(True);
    end;
  Position := 1;
  while (Position <= Length(Header)) and IsWhitespaceByte(Header[Position]) do
    Inc(Position);
  if Copy(Header, Position, 5) = '<?xml' then
  begin
    Essence := 'text/xml';
    Exit(True);
  end;
  if StartsWithBytes(Header, '%PDF-') then
  begin
    Essence := 'application/pdf';
    Exit(True);
  end;
  Essence := '';
  Result := False;
end;

function MatchImageSignature(const Header: string): string;
begin
  if StartsWithBytes(Header, #0#0#1#0) then
    Exit('image/x-icon');
  if StartsWithBytes(Header, #0#0#2#0) then
    Exit('image/x-icon');
  if StartsWithBytes(Header, 'BM') then
    Exit('image/bmp');
  if StartsWithBytes(Header, 'GIF87a') or StartsWithBytes(Header, 'GIF89a') then
    Exit('image/gif');
  if StartsWithBytes(Header, 'RIFF') and (Copy(Header, 9, 6) = 'WEBPVP') then
    Exit('image/webp');
  if StartsWithBytes(Header, #$89'PNG'#13#10#26#10) then
    Exit('image/png');
  if StartsWithBytes(Header, #$FF#$D8#$FF) then
    Exit('image/jpeg');
  { JPEG XL, as a codestream and in its container (not in the standard's
    table; libimage reads it). }
  if StartsWithBytes(Header, #$FF#$0A) or StartsWithBytes(Header, #0#0#0#$0C'JXL '#$0D#$0A#$87#$0A) then
    Exit('image/jxl');
  if StartsWithBytes(Header, 'II*'#0) or StartsWithBytes(Header, 'MM'#0'*') then
    Exit('image/tiff');
  Result := '';
end;

function MatchArchiveSignature(const Header: string): string;
begin
  if StartsWithBytes(Header, #$1F#$8B#$08) then
    Exit('application/x-gzip');
  if StartsWithBytes(Header, 'PK'#3#4) then
    Exit('application/zip');
  if StartsWithBytes(Header, 'Rar!'#$1A#7#0) then
    Exit('application/x-rar-compressed');
  Result := '';
end;

function MatchAudioVideoSignature(const Header: string): string;
begin
  if StartsWithBytes(Header, 'FORM') and (Copy(Header, 9, 4) = 'AIFF') then
    Exit('audio/aiff');
  if StartsWithBytes(Header, 'ID3') then
    Exit('audio/mpeg');
  if StartsWithBytes(Header, 'OggS'#0) then
    Exit('application/ogg');
  if StartsWithBytes(Header, 'MThd'#0#0#0#6) then
    Exit('audio/midi');
  if StartsWithBytes(Header, 'RIFF') and (Copy(Header, 9, 4) = 'AVI ') then
    Exit('video/avi');
  if StartsWithBytes(Header, 'RIFF') and (Copy(Header, 9, 4) = 'WAVE') then
    Exit('audio/wave');
  if StartsWithBytes(Header, #$1A#$45#$DF#$A3) then
    Exit('video/webm');
  if (Length(Header) >= 12) and (Copy(Header, 5, 4) = 'ftyp') then
    Exit('video/mp4');
  Result := '';
end;

function MatchesByteOrderMark(const Header: string): Boolean;
begin
  Result := StartsWithBytes(Header, #$FE#$FF) or StartsWithBytes(Header, #$FF#$FE) or
    StartsWithBytes(Header, #$EF#$BB#$BF);
end;

function IdentifyUnknownMimeType(const Header: string; SniffScriptable: Boolean): string;
begin
  if SniffScriptable and MatchesScriptableType(Header, Result) then
    Exit;
  if StartsWithBytes(Header, '%!PS-Adobe-') then
    Exit('application/postscript');
  if MatchesByteOrderMark(Header) then
    Exit('text/plain');
  Result := MatchImageSignature(Header);
  if Result <> '' then
    Exit;
  Result := MatchAudioVideoSignature(Header);
  if Result <> '' then
    Exit;
  Result := MatchArchiveSignature(Header);
  if Result <> '' then
    Exit;
  if not ContainsBinaryDataBytes(Header) then
    Exit('text/plain');
  Result := 'application/octet-stream';
end;

function DistinguishTextOrBinary(const Header: string): string;
begin
  if MatchesByteOrderMark(Header) or not ContainsBinaryDataBytes(Header) then
    Exit('text/plain');
  Result := IdentifyUnknownMimeType(Header, False);
end;

function IsUnknownMimeType(const Essence: string): Boolean;
begin
  Result := (Essence = '') or (Essence = 'unknown/unknown') or (Essence = 'application/unknown') or
    (Essence = '*/*');
end;

function IsApacheBugContentType(const RawContentType: string): Boolean;
begin
  Result := (RawContentType = 'text/plain') or (RawContentType = 'text/plain; charset=ISO-8859-1') or
    (RawContentType = 'text/plain; charset=iso-8859-1') or (RawContentType = 'text/plain; charset=UTF-8');
end;

function SniffMimeType(const SuppliedEssence: string; const Header: string; constref Options: TSniffOptions): string;
var
  Matched: string;
begin
  if IsUnknownMimeType(SuppliedEssence) then
    Exit(IdentifyUnknownMimeType(Header, not Options.NoSniff));
  if Options.NoSniff then
    Exit(SuppliedEssence);
  if Options.CheckForApacheBug then
    Exit(DistinguishTextOrBinary(Header));
  if IsXmlMimeType(SuppliedEssence) or IsHtmlMimeType(SuppliedEssence) then
    Exit(SuppliedEssence);
  if IsImageMimeType(SuppliedEssence) then
  begin
    Matched := MatchImageSignature(Header);
    if Matched <> '' then
      Exit(Matched);
  end;
  Result := SuppliedEssence;
end;

function SniffImageMimeType(const SuppliedEssence: string; const Header: string): string;
begin
  if IsXmlMimeType(SuppliedEssence) then
    Exit(SuppliedEssence);
  Result := MatchImageSignature(Header);
  if Result = '' then
    Result := SuppliedEssence;
end;

end.
