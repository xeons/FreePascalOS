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
  Reading an ICC profile (versions 2 and 4): the 128-byte header (size,
  version, device class, colour space, PCS, rendering intent), the tag
  table, and the tags colour conversion needs:

    rXYZ gXYZ bXYZ    the colorants: the PCS XYZ of full red, green, blue
    rTRC gTRC bTRC    their tone curves (curv or para)
    kTRC              a grey profile's tone curve
    wtpt              the media white point
    chad              the chromatic adaptation matrix (sf32, 3 x 3) that
                      took the colorants from the original illuminant
                      to D50
    A2B0              the perceptual device to PCS LUT (mft1, mft2, mAB)
    desc              the description (v2 textDescriptionType, v4
                      multiLocalizedUnicodeType: its first record)

  A profile that breaks the rules where it matters (too short, a size
  beyond the data, a tag outside it) is refused; tags that cannot be
  read are left out, and what is missing decides what conversion can
  be done (Image.ColorProfiles.Transforms).
}
unit Image.ColorProfiles.Reading;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.ColorProfiles.Matrices,
  Image.ColorProfiles.Curves,
  Image.ColorProfiles.Luts;

type
  TIccProfile = record
    Valid: Boolean;
    VersionMajor: LongInt;
    VersionMinor: LongInt;
    DeviceClass: LongWord;
    ColorSpace: LongWord;
    Pcs: LongWord;
    RenderingIntent: LongWord;
    Description: string;

    HasColorants: Boolean;
    RedColorant: TColorVector;
    GreenColorant: TColorVector;
    BlueColorant: TColorVector;
    HasRgbCurves: Boolean;
    RgbCurves: array[0..2] of TToneCurve;
    HasGreyCurve: Boolean;
    GreyCurve: TToneCurve;
    HasMediaWhite: Boolean;
    MediaWhite: TColorVector;
    HasAdaptation: Boolean;
    Adaptation: TColorMatrix;
    { A2B0 is there (DeviceToPcs.Kind <> IccLutNone when it could be read). }
    HasDeviceToPcs: Boolean;
    DeviceToPcs: TIccLut;
  end;

{ The profile in Data; Valid is False when it is not one. }
function ReadIccProfile(const Data: TBytes): TIccProfile;
function IccColorSpaceIsRgb(constref Profile: TIccProfile): Boolean;
function IccColorSpaceIsGrey(constref Profile: TIccProfile): Boolean;
function IccColorSpaceIsCmyk(constref Profile: TIccProfile): Boolean;
function IccPcsIsLab(constref Profile: TIccProfile): Boolean;

implementation

uses
  Image.ColorProfiles.Numbers;

const
  HeaderSize = 128;
  TagEntrySize = 12;
  MaximumTags = 1024;
  ProfileMagic = 'acsp';

type
  TTagLocation = record
    Offset: PtrInt;
    Limit: PtrInt;
  end;

function IccColorSpaceIsRgb(constref Profile: TIccProfile): Boolean;
begin
  Result := Profile.ColorSpace = SignatureOf('RGB ');
end;

function IccColorSpaceIsGrey(constref Profile: TIccProfile): Boolean;
begin
  Result := Profile.ColorSpace = SignatureOf('GRAY');
end;

function IccColorSpaceIsCmyk(constref Profile: TIccProfile): Boolean;
begin
  Result := Profile.ColorSpace = SignatureOf('CMYK');
end;

function IccPcsIsLab(constref Profile: TIccProfile): Boolean;
begin
  Result := Profile.Pcs = SignatureOf('Lab ');
end;

function FindTag(const Data: TBytes; Signature: LongWord; out Location: TTagLocation): Boolean;
var
  Count: LongWord;
  Index: LongWord;
  Entry: PtrInt;
  Offset: Int64;
  Size: Int64;
begin
  Result := False;
  Location := Default(TTagLocation);
  Count := ReadProfileLong(Data, HeaderSize);
  if Count > MaximumTags then
    Count := MaximumTags;
  Index := 0;
  while Index < Count do
  begin
    Entry := HeaderSize + 4 + PtrInt(Index) * TagEntrySize;
    if Entry + TagEntrySize > Length(Data) then
      Exit;
    if ReadProfileLong(Data, Entry) = Signature then
    begin
      Offset := ReadProfileLong(Data, Entry + 4);
      Size := ReadProfileLong(Data, Entry + 8);
      if (Offset < HeaderSize) or (Size < 8) or (Offset + Size > Length(Data)) then
        Exit;
      Location.Offset := Offset;
      Location.Limit := Offset + Size;
      Exit(True);
    end;
    Inc(Index);
  end;
end;

function ReadXyzTag(const Data: TBytes; Signature: LongWord; out Value: TColorVector): Boolean;
var
  Location: TTagLocation;
begin
  Value := MakeVector(0, 0, 0);
  if not FindTag(Data, Signature, Location) or (Location.Offset + 20 > Location.Limit) or
    (ReadProfileLong(Data, Location.Offset) <> SignatureOf('XYZ ')) then
    Exit(False);
  Value := MakeVector(ReadProfileFixed(Data, Location.Offset + 8), ReadProfileFixed(Data, Location.Offset + 12),
    ReadProfileFixed(Data, Location.Offset + 16));
  Result := True;
end;

function ReadCurveTag(const Data: TBytes; Signature: LongWord; out Curve: TToneCurve): Boolean;
var
  Location: TTagLocation;
  Size: PtrInt;
begin
  Curve := IdentityCurve;
  Result := FindTag(Data, Signature, Location) and ReadToneCurve(Data, Location.Offset, Location.Limit, Curve, Size);
end;

function ReadAdaptationTag(const Data: TBytes; out Matrix: TColorMatrix): Boolean;
var
  Location: TTagLocation;
  Row: LongInt;
  Column: LongInt;
begin
  Matrix := IdentityMatrix;
  if not FindTag(Data, SignatureOf('chad'), Location) or (Location.Offset + 44 > Location.Limit) or
    (ReadProfileLong(Data, Location.Offset) <> SignatureOf('sf32')) then
    Exit(False);
  for Row := 0 to 2 do
    for Column := 0 to 2 do
      Matrix[Row, Column] := ReadProfileFixed(Data, Location.Offset + 8 + 4 * (3 * Row + Column));
  Result := True;
end;

function AsciiText(const Data: TBytes; Offset, Count: PtrInt): string;
var
  Index: PtrInt;
begin
  Result := '';
  for Index := 0 to Count - 1 do
  begin
    if Data[Offset + Index] = 0 then
      Break;
    if Data[Offset + Index] < 128 then
      Result := Result + Chr(Data[Offset + Index]);
  end;
end;

{ UTF-16BE, characters outside ASCII as '?'. }
function Utf16Text(const Data: TBytes; Offset, Count: PtrInt): string;
var
  Index: PtrInt;
  Character: Word;
begin
  Result := '';
  Index := 0;
  while Index + 1 < Count do
  begin
    Character := ReadProfileWord(Data, Offset + Index);
    if Character = 0 then
      Break;
    if Character < 128 then
      Result := Result + Chr(Character)
    else
      Result := Result + '?';
    Inc(Index, 2);
  end;
end;

function ReadDescription(const Data: TBytes): string;
var
  Location: TTagLocation;
  Signature: LongWord;
  Count: Int64;
  RecordCount: LongWord;
  TextOffset: Int64;
  TextLength: Int64;
begin
  Result := '';
  if not FindTag(Data, SignatureOf('desc'), Location) or (Location.Offset + 12 > Location.Limit) then
    Exit;
  Signature := ReadProfileLong(Data, Location.Offset);
  if Signature = SignatureOf('desc') then
  begin
    Count := ReadProfileLong(Data, Location.Offset + 8);
    if Location.Offset + 12 + Count <= Location.Limit then
      Result := AsciiText(Data, Location.Offset + 12, Count);
  end
  else if Signature = SignatureOf('mluc') then
  begin
    if Location.Offset + 28 > Location.Limit then
      Exit;
    RecordCount := ReadProfileLong(Data, Location.Offset + 8);
    if RecordCount = 0 then
      Exit;
    TextLength := ReadProfileLong(Data, Location.Offset + 20);
    TextOffset := ReadProfileLong(Data, Location.Offset + 24);
    if Location.Offset + TextOffset + TextLength <= Location.Limit then
      Result := Utf16Text(Data, Location.Offset + TextOffset, TextLength);
  end;
end;

procedure ReadMatrixShaper(const Data: TBytes; var Profile: TIccProfile);
begin
  Profile.HasColorants := ReadXyzTag(Data, SignatureOf('rXYZ'), Profile.RedColorant) and
    ReadXyzTag(Data, SignatureOf('gXYZ'), Profile.GreenColorant) and
    ReadXyzTag(Data, SignatureOf('bXYZ'), Profile.BlueColorant);
  Profile.HasRgbCurves := ReadCurveTag(Data, SignatureOf('rTRC'), Profile.RgbCurves[0]) and
    ReadCurveTag(Data, SignatureOf('gTRC'), Profile.RgbCurves[1]) and
    ReadCurveTag(Data, SignatureOf('bTRC'), Profile.RgbCurves[2]);
  Profile.HasGreyCurve := ReadCurveTag(Data, SignatureOf('kTRC'), Profile.GreyCurve);
end;

procedure ReadDeviceToPcs(const Data: TBytes; var Profile: TIccProfile);
var
  Location: TTagLocation;
begin
  Profile.HasDeviceToPcs := FindTag(Data, SignatureOf('A2B0'), Location);
  if Profile.HasDeviceToPcs then
    ReadIccLut(Data, Location.Offset, Location.Limit, Profile.DeviceToPcs);
end;

function ReadIccProfile(const Data: TBytes): TIccProfile;
var
  Size: Int64;
  Version: LongWord;
begin
  Result := Default(TIccProfile);
  Result.Adaptation := IdentityMatrix;
  if Length(Data) < HeaderSize + 4 then
    Exit;
  Size := ReadProfileLong(Data, 0);
  if (Size < HeaderSize + 4) or (Size > Length(Data)) or (ReadProfileLong(Data, 36) <> SignatureOf(ProfileMagic)) then
    Exit;
  Version := ReadProfileLong(Data, 8);
  Result.VersionMajor := Version shr 24;
  Result.VersionMinor := (Version shr 20) and $F;
  Result.DeviceClass := ReadProfileLong(Data, 12);
  Result.ColorSpace := ReadProfileLong(Data, 16);
  Result.Pcs := ReadProfileLong(Data, 20);
  Result.RenderingIntent := ReadProfileLong(Data, 64);
  if (Result.Pcs <> SignatureOf('XYZ ')) and (Result.Pcs <> SignatureOf('Lab ')) then
    Exit;
  Result.Description := ReadDescription(Data);
  ReadMatrixShaper(Data, Result);
  Result.HasMediaWhite := ReadXyzTag(Data, SignatureOf('wtpt'), Result.MediaWhite);
  Result.HasAdaptation := ReadAdaptationTag(Data, Result.Adaptation);
  ReadDeviceToPcs(Data, Result);
  Result.Valid := True;
end;

end.
