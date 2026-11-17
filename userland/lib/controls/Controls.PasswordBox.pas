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
  Password boxes: one line whose characters show as dots.

  Unlike an edit box (whose text is a string, copied each time it
  changes and left behind in freed memory) the password is kept in one
  buffer of the box's own, UTF-8 and zero-terminated, which is
  overwritten whenever characters leave it and before it is freed.
  Password is that buffer, to hand straight to whatever checks it
  (Util.Passwords takes a PChar); nothing here makes a string of it.

  Typing adds a character at the end and Backspace takes the last one
  away (the caret stays at the end). Ctrl+A selects everything, so the
  next character or Backspace replaces it all; a click lets go of the
  selection. Nothing is cut, copied or pasted: a password never goes
  through the clipboard. Enter and Escape are left for the window (its
  default and cancel buttons).
}
unit Controls.PasswordBox;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base;

const
  { The longest password, in bytes of UTF-8. }
  PasswordCapacity = 256;

type
  TPasswordBox = class(TControl)
  private
    FBuffer: PChar;
    FByteCount: LongInt;
    FAllSelected: Boolean;
    function CharacterCount: LongInt;
    procedure Append(CodePoint: LongWord);
    procedure RemoveLast;
    procedure Wipe;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    { Overwrites the password and empties the box. }
    procedure Clear;
    procedure SelectAll;
    function IsEmpty: Boolean;
    { What was typed: the box's own buffer (UTF-8, zero-terminated),
      good until the box changes; not to be copied into a string. }
    property Password: PChar read FBuffer;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Protocol,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.Painting;

const
  { U+2022, the bullet, in UTF-8: what each character shows as. }
  HiddenCharacter = #$E2#$80#$A2;

constructor TPasswordBox.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  PointerShape := PointerTextBeam;
  FBuffer := GetMem(PasswordCapacity + 1);
  FillChar(FBuffer^, PasswordCapacity + 1, 0);
end;

destructor TPasswordBox.Destroy;
begin
  Wipe;
  FreeMem(FBuffer);
  FBuffer := nil;
  inherited Destroy;
end;

procedure TPasswordBox.Wipe;
begin
  FillChar(FBuffer^, PasswordCapacity + 1, 0);
  FByteCount := 0;
  FAllSelected := False;
end;

procedure TPasswordBox.Clear;
begin
  Wipe;
  Invalidate;
  Changed;
end;

procedure TPasswordBox.SelectAll;
begin
  FAllSelected := FByteCount > 0;
  Invalidate;
end;

function TPasswordBox.IsEmpty: Boolean;
begin
  Result := FByteCount = 0;
end;

{ Every byte but UTF-8's continuation bytes (10xxxxxx) starts a character. }
function TPasswordBox.CharacterCount: LongInt;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to FByteCount - 1 do
    if (Byte(FBuffer[Index]) and $C0) <> $80 then
      Inc(Result);
end;

procedure TPasswordBox.Append(CodePoint: LongWord);
var
  Bytes: array[0..3] of Byte;
  Count: LongInt;
  Index: LongInt;
begin
  if CodePoint < $80 then
  begin
    Bytes[0] := CodePoint;
    Count := 1;
  end
  else if CodePoint < $800 then
  begin
    Bytes[0] := $C0 or (CodePoint shr 6);
    Bytes[1] := $80 or (CodePoint and $3F);
    Count := 2;
  end
  else if CodePoint < $10000 then
  begin
    Bytes[0] := $E0 or (CodePoint shr 12);
    Bytes[1] := $80 or ((CodePoint shr 6) and $3F);
    Bytes[2] := $80 or (CodePoint and $3F);
    Count := 3;
  end
  else
  begin
    Bytes[0] := $F0 or ((CodePoint shr 18) and $07);
    Bytes[1] := $80 or ((CodePoint shr 12) and $3F);
    Bytes[2] := $80 or ((CodePoint shr 6) and $3F);
    Bytes[3] := $80 or (CodePoint and $3F);
    Count := 4;
  end;
  if FByteCount + Count > PasswordCapacity then
    Exit;
  for Index := 0 to Count - 1 do
    FBuffer[FByteCount + Index] := Char(Bytes[Index]);
  FByteCount := FByteCount + Count;
  FBuffer[FByteCount] := #0;
  FillChar(Bytes, SizeOf(Bytes), 0);
end;

procedure TPasswordBox.RemoveLast;
begin
  while FByteCount > 0 do
  begin
    Dec(FByteCount);
    if (Byte(FBuffer[FByteCount]) and $C0) <> $80 then
    begin
      FBuffer[FByteCount] := #0;
      Exit;
    end;
    FBuffer[FByteCount] := #0;
  end;
end;

function TPasswordBox.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := True;
  if (Code = KeyA) and ((Modifiers and ModifierControl) <> 0) then
  begin
    SelectAll;
    Exit;
  end;
  if Code = KeyBackspace then
  begin
    if FAllSelected then
      Wipe
    else
      RemoveLast;
  end
  else if (Character >= 32) and (Character <> 127) and ((Modifiers and ModifierControl) = 0) then
  begin
    if FAllSelected then
      Wipe;
    Append(Character);
  end
  else
    Exit(False);
  FAllSelected := False;
  Invalidate;
  Changed;
end;

procedure TPasswordBox.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if FAllSelected then
  begin
    FAllSelected := False;
    Invalidate;
  end;
end;

procedure TPasswordBox.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Inner: TCanvas;
  Dots: string;
  Index: LongInt;
  TextLeft: LongInt;
  TextTop: LongInt;
  DotsWidth: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if Enabled then
    FillRectangle(Canvas, Box, Theme.Field)
  else
    FillRectangle(Canvas, Box, Theme.Face);
  DrawSunkenBevel(Canvas, Box);
  if ControlFace = nil then
    Exit;
  Inner := Canvas;
  NarrowCanvasClip(Inner, InflateRectangle(Box, -BevelWidth));
  Dots := '';
  for Index := 1 to CharacterCount do
    Dots := Dots + HiddenCharacter;
  DotsWidth := TextWidth(ControlFace, Dots);
  TextLeft := Scaled(4);
  { The end stays in view: the dots scroll left once they fill the box. }
  if TextLeft + DotsWidth > RectangleWidth(Box) - Scaled(4) then
    TextLeft := RectangleWidth(Box) - Scaled(4) - DotsWidth;
  TextTop := (RectangleHeight(Box) - TextHeight(ControlFace)) div 2;
  if FAllSelected and Focused then
  begin
    FillRectangle(Inner, MakeRectangle(TextLeft, TextTop, DotsWidth, TextHeight(ControlFace)), Theme.Selection);
    DrawTextInBox(Inner, ControlFace, Dots, MakeRectangle(TextLeft, TextTop, 1 shl 20, TextHeight(ControlFace)),
      AlignTextLeft, Theme.SelectionText);
  end
  else if Enabled then
    DrawTextInBox(Inner, ControlFace, Dots, MakeRectangle(TextLeft, TextTop, 1 shl 20, TextHeight(ControlFace)),
      AlignTextLeft, Theme.FieldText)
  else
    DrawDisabledText(Inner, ControlFace, Dots, TextLeft, TextTop);
  if Focused and Enabled then
    FillRectangle(Inner, MakeRectangle(TextLeft + DotsWidth, TextTop, Scaled(1), TextHeight(ControlFace)),
      Theme.FieldText);
end;

end.
