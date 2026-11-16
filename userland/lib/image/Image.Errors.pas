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
  What goes wrong reading or writing an image: EImageError with a
  reason a program can act on (a format it does not know, a file cut
  short, one that breaks its format's rules, a feature not supported,
  an embedded PNG with no PNG decoder registered) and a message for people.

  Decoders raise it; the convenience layer (Image.Files) passes it on,
  and its Try routines turn it into a result.
}
unit Image.Errors;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TImageErrorReason = (
    ImageErrorNone,
    ImageErrorUnknownFormat,
    ImageErrorTruncated,
    ImageErrorMalformed,
    ImageErrorUnsupported,
    ImageErrorNeedsPng,
    ImageErrorTooLarge,
    ImageErrorNoEncoder,
    ImageErrorFile
  );

  EImageError = class(Exception)
  private
    FReason: TImageErrorReason;
  public
    constructor Create(Reason: TImageErrorReason; const Detail: string);
    property Reason: TImageErrorReason read FReason;
  end;

{ Raises EImageError. }
procedure RaiseImageError(Reason: TImageErrorReason; const Detail: string);
function ImageErrorReasonText(Reason: TImageErrorReason): string;

implementation

constructor EImageError.Create(Reason: TImageErrorReason; const Detail: string);
begin
  FReason := Reason;
  if Detail = '' then
    inherited Create(ImageErrorReasonText(Reason))
  else
    inherited Create(ImageErrorReasonText(Reason) + ': ' + Detail);
end;

procedure RaiseImageError(Reason: TImageErrorReason; const Detail: string);
begin
  raise EImageError.Create(Reason, Detail);
end;

function ImageErrorReasonText(Reason: TImageErrorReason): string;
begin
  case Reason of
    ImageErrorNone: Result := 'no error';
    ImageErrorUnknownFormat: Result := 'not an image format known';
    ImageErrorTruncated: Result := 'the image is cut short';
    ImageErrorMalformed: Result := 'the image is malformed';
    ImageErrorUnsupported: Result := 'the image uses a feature not supported';
    ImageErrorNeedsPng: Result := 'the image needs PNG decoding';
    ImageErrorTooLarge: Result := 'the image is too large';
    ImageErrorNoEncoder: Result := 'no encoder for that format';
    ImageErrorFile: Result := 'the file cannot be read or written';
  else
    Result := 'image error';
  end;
end;

end.
