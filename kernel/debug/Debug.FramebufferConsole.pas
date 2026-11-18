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
  Text console drawn directly into the boot framebuffer.

  It needs nothing but the framebuffer address handed over by the loader,
  so it is available from the start of kernel initialization until a real
  display driver takes over. Callers are responsible for locking; the
  kernel debug output unit serializes access.

  Text is UTF-8; the font (Debug.ConsoleFont.inc) has ASCII, Latin-1 and
  a few more characters, and anything else shows as a question mark. The
  escape sequences programs use (ESC [ ... : cursor movement and
  positioning, erasing in a line or the screen, colours) are carried out;
  others are swallowed.

  Once the kernel heap is there, the console keeps a copy of the screen
  in ordinary memory (StartFramebufferShadow): every pixel is written to
  both, and scrolling moves the copy and writes the framebuffer, never
  reading video memory, which is very slow to read.

  Pixels are 32 bits everywhere but in the framebuffer itself, which may
  be 16 bits (r5g6b5: a Raspberry Pi firmware's simple-framebuffer):
  every write to it goes through WriteScanLine, which narrows them.
}
unit Debug.FramebufferConsole;

{$mode objfpc}
{$pointermath on}

interface

uses
  Boot.Information;

type
  TColor = record
    Red: Byte;
    Green: Byte;
    Blue: Byte;
  end;

  TConsoleModeRestorer = procedure;

const
  ColorBlack: TColor = (Red: $00; Green: $00; Blue: $00);
  ColorLightGray: TColor = (Red: $C0; Green: $C0; Blue: $C0);
  ColorWhite: TColor = (Red: $FF; Green: $FF; Blue: $FF);
  ColorCyan: TColor = (Red: $40; Green: $D0; Blue: $E0);
  ColorYellow: TColor = (Red: $F0; Green: $D0; Blue: $40);
  ColorGreen: TColor = (Red: $60; Green: $D0; Blue: $60);
  ColorRed: TColor = (Red: $F0; Green: $50; Blue: $50);
  ColorDarkRed: TColor = (Red: $60; Green: $00; Blue: $00);
  ColorDarkBlue: TColor = (Red: $10; Green: $18; Blue: $30);

{ FramebufferVirtualBase is where the framebuffer is mapped. }
procedure InitializeFramebufferConsole(const Framebuffer: TFramebufferInformation;
  FramebufferVirtualBase: Pointer);

function FramebufferConsoleIsAvailable: Boolean;

procedure ConsoleWriteCharacter(Character: Char);
procedure ConsoleSetForegroundColor(const Color: TColor);
procedure ConsoleSetBackgroundColor(const Color: TColor);
procedure ConsoleClearScreen;

function ConsoleColumnCount: LongWord;
function ConsoleRowCount: LongWord;

{ Gives the console a copy of the screen in ordinary memory (Shadow,
  Width x Height pixels), once the kernel heap can provide one; from then
  on scrolling moves the copy and only writes the framebuffer. }
procedure StartFramebufferShadow(Shadow: PLongWord);
{ Draws the whole screen again from the shadow (the display lost it). }
procedure ConsoleRedraw;
{ A program has the screen (the display device): the console goes on
  drawing into its shadow only, until ResumeConsoleDrawing, which draws
  the screen again from it. }
procedure SuspendConsoleDrawing;
procedure ResumeConsoleDrawing;
function ConsoleDrawingIsSuspended: Boolean;
{ Called by ResumeConsoleDrawing before drawing again: the display
  driver sets the boot mode back if the program changed it, as the
  console draws at that size. }
procedure SetConsoleModeRestorer(Restorer: TConsoleModeRestorer);
{ The bytes of a shadow for this framebuffer; 0 without a console. }
function FramebufferShadowSize: QWord;

implementation

uses
  Runtime.Memory;

{$include Debug.ConsoleFont.inc}

const
  TabWidth = 8;
  ConsoleMargin = 8;
  MaximumParameters = 8;

type
  { Where the console is in decoding its input. }
  TInputState = (InputNormal, InputEscape, InputControlSequence);

  TConsoleState = record
    IsAvailable: Boolean;
    { The framebuffer: BytesPerPixel 4, or 2 (PixelFormatRedGreenBlue565). }
    Pixels: PByte;
    BytesPerPixel: LongWord;
    PixelsPerScanLine: LongWord;
    WidthInPixels: LongWord;
    HeightInPixels: LongWord;
    PixelFormat: LongWord;
    { The copy of the screen, WidthInPixels pixels per line; nil before
      StartFramebufferShadow. }
    Shadow: PLongWord;
    { A program has the screen: only the shadow is drawn. }
    DrawingSuspended: Boolean;
    Columns: LongWord;
    Rows: LongWord;
    CursorColumn: LongWord;
    CursorRow: LongWord;
    ForegroundPixel: LongWord;
    BackgroundPixel: LongWord;
    DefaultForegroundPixel: LongWord;
    DefaultBackgroundPixel: LongWord;
    { UTF-8: the character being put together and how many bytes it
      still needs. }
    PendingCodePoint: LongWord;
    PendingBytes: Integer;
    { Escape sequences (ESC [ parameters final). }
    State: TInputState;
    Parameters: array[0..MaximumParameters - 1] of LongWord;
    ParameterCount: Integer;
  end;

var
  Console: TConsoleState;
  ModeRestorer: TConsoleModeRestorer;

{ --- Pixels ------------------------------------------------------------------ }

{ A 32-bit pixel (blue in the low byte) as r5g6b5. }
function NarrowPixel(Pixel: LongWord): Word;
begin
  Result := Word(((Pixel shr 8) and $F800) or ((Pixel shr 5) and $07E0) or ((Pixel shr 3) and $001F));
end;

function WidenPixel(Pixel: Word): LongWord;
begin
  Result := (LongWord(Pixel and $F800) shl 8) or (LongWord(Pixel and $07E0) shl 5) or
    (LongWord(Pixel and $001F) shl 3);
end;

function EncodePixel(const Color: TColor): LongWord;
begin
  if Console.PixelFormat = PixelFormatRedGreenBlue then
    Result := LongWord(Color.Red) or (LongWord(Color.Green) shl 8) or (LongWord(Color.Blue) shl 16)
  else
    Result := LongWord(Color.Blue) or (LongWord(Color.Green) shl 8) or (LongWord(Color.Red) shl 16);
end;

function ScanLineAddress(PixelRow: LongWord): PByte;
begin
  Result := Console.Pixels + QWord(PixelRow) * Console.PixelsPerScanLine * Console.BytesPerPixel;
end;

{ Count 32-bit pixels to the framebuffer's line PixelRow at Left. }
procedure WriteScanLine(PixelRow, Left: LongWord; Source: PLongWord; Count: LongWord);
var
  Line: PWord;
  Index: LongWord;
begin
  if Console.BytesPerPixel = 4 then
  begin
    CopyMemory(PLongWord(ScanLineAddress(PixelRow)) + Left, Source, Count * SizeOf(LongWord));
    Exit;
  end;
  Line := PWord(ScanLineAddress(PixelRow)) + Left;
  Index := 0;
  while Index < Count do
  begin
    Line[Index] := NarrowPixel(Source[Index]);
    Inc(Index);
  end;
end;

{ The framebuffer's line PixelRow as Count 32-bit pixels. }
procedure ReadScanLine(PixelRow: LongWord; Destination: PLongWord; Count: LongWord);
var
  Line: PWord;
  Index: LongWord;
begin
  if Console.BytesPerPixel = 4 then
  begin
    CopyMemory(Destination, ScanLineAddress(PixelRow), Count * SizeOf(LongWord));
    Exit;
  end;
  Line := PWord(ScanLineAddress(PixelRow));
  Index := 0;
  while Index < Count do
  begin
    Destination[Index] := WidenPixel(Line[Index]);
    Inc(Index);
  end;
end;

function ShadowLineAddress(PixelRow: LongWord): PLongWord;
begin
  Result := Console.Shadow + QWord(PixelRow) * Console.WidthInPixels;
end;

{ Writes Count pixels to a line, at Left: into the shadow (if any) and the
  framebuffer. }
procedure PutPixels(PixelRow, Left: LongWord; Source: PLongWord; Count: LongWord);
begin
  if Console.Shadow <> nil then
    CopyMemory(ShadowLineAddress(PixelRow) + Left, Source, Count * SizeOf(LongWord));
  if not Console.DrawingSuspended then
    WriteScanLine(PixelRow, Left, Source, Count);
end;

procedure FillRectangle(Left, Top, Width, Height: LongWord; Pixel: LongWord);
var
  RowOffset: LongWord;
  ColumnOffset: LongWord;
  Line: PLongWord;
  NarrowLine: PWord;
  Narrow: Word;
begin
  Narrow := NarrowPixel(Pixel);
  RowOffset := 0;
  while RowOffset < Height do
  begin
    if not Console.DrawingSuspended then
    begin
      if Console.BytesPerPixel = 4 then
      begin
        Line := PLongWord(ScanLineAddress(Top + RowOffset));
        for ColumnOffset := 0 to Width - 1 do
          Line[Left + ColumnOffset] := Pixel;
      end
      else
      begin
        NarrowLine := PWord(ScanLineAddress(Top + RowOffset));
        for ColumnOffset := 0 to Width - 1 do
          NarrowLine[Left + ColumnOffset] := Narrow;
      end;
    end;
    if Console.Shadow <> nil then
    begin
      Line := ShadowLineAddress(Top + RowOffset);
      for ColumnOffset := 0 to Width - 1 do
        Line[Left + ColumnOffset] := Pixel;
    end;
    Inc(RowOffset);
  end;
end;

procedure InitializeFramebufferConsole(const Framebuffer: TFramebufferInformation;
  FramebufferVirtualBase: Pointer);
begin
  Console.IsAvailable := False;
  if (FramebufferVirtualBase = nil) or (Framebuffer.Width < 2 * ConsoleMargin + ConsoleFontWidth) or
     (Framebuffer.Height < 2 * ConsoleMargin + ConsoleFontHeight) then
    Exit;

  Console.Pixels := PByte(FramebufferVirtualBase);
  if Framebuffer.PixelFormat = PixelFormatRedGreenBlue565 then
    Console.BytesPerPixel := 2
  else
    Console.BytesPerPixel := 4;
  Console.PixelsPerScanLine := Framebuffer.PixelsPerScanLine;
  Console.WidthInPixels := Framebuffer.Width;
  Console.HeightInPixels := Framebuffer.Height;
  Console.PixelFormat := Framebuffer.PixelFormat;
  Console.Shadow := nil;
  Console.Columns := (Framebuffer.Width - 2 * ConsoleMargin) div ConsoleFontWidth;
  Console.Rows := (Framebuffer.Height - 2 * ConsoleMargin) div ConsoleFontHeight;
  Console.DefaultForegroundPixel := EncodePixel(ColorLightGray);
  Console.DefaultBackgroundPixel := EncodePixel(ColorDarkBlue);
  Console.ForegroundPixel := Console.DefaultForegroundPixel;
  Console.BackgroundPixel := Console.DefaultBackgroundPixel;
  Console.State := InputNormal;
  Console.PendingBytes := 0;
  Console.IsAvailable := True;

  ConsoleClearScreen;
end;

function FramebufferShadowSize: QWord;
begin
  if not Console.IsAvailable then
    Exit(0);
  Result := QWord(Console.WidthInPixels) * Console.HeightInPixels * SizeOf(LongWord);
end;

procedure StartFramebufferShadow(Shadow: PLongWord);
var
  PixelRow: LongWord;
begin
  if not Console.IsAvailable or (Shadow = nil) or (Console.Shadow <> nil) then
    Exit;
  { The one time the framebuffer is read. }
  for PixelRow := 0 to Console.HeightInPixels - 1 do
    ReadScanLine(PixelRow, Shadow + QWord(PixelRow) * Console.WidthInPixels, Console.WidthInPixels);
  Console.Shadow := Shadow;
end;

procedure ConsoleRedraw;
var
  PixelRow: LongWord;
begin
  if not Console.IsAvailable or (Console.Shadow = nil) or Console.DrawingSuspended then
    Exit;
  for PixelRow := 0 to Console.HeightInPixels - 1 do
    WriteScanLine(PixelRow, 0, Console.Shadow + QWord(PixelRow) * Console.WidthInPixels,
      Console.WidthInPixels);
end;

procedure SuspendConsoleDrawing;
begin
  Console.DrawingSuspended := True;
end;

procedure SetConsoleModeRestorer(Restorer: TConsoleModeRestorer);
begin
  ModeRestorer := Restorer;
end;

procedure ResumeConsoleDrawing;
begin
  if not Console.DrawingSuspended then
    Exit;
  if ModeRestorer <> nil then
    ModeRestorer;
  Console.DrawingSuspended := False;
  ConsoleRedraw;
end;

function ConsoleDrawingIsSuspended: Boolean;
begin
  Result := Console.DrawingSuspended;
end;

function FramebufferConsoleIsAvailable: Boolean;
begin
  Result := Console.IsAvailable;
end;

function ConsoleColumnCount: LongWord;
begin
  Result := Console.Columns;
end;

function ConsoleRowCount: LongWord;
begin
  Result := Console.Rows;
end;

procedure ConsoleSetForegroundColor(const Color: TColor);
begin
  Console.ForegroundPixel := EncodePixel(Color);
end;

procedure ConsoleSetBackgroundColor(const Color: TColor);
begin
  Console.BackgroundPixel := EncodePixel(Color);
end;

procedure ConsoleClearScreen;
begin
  if not Console.IsAvailable then
    Exit;
  FillRectangle(0, 0, Console.WidthInPixels, Console.HeightInPixels, Console.BackgroundPixel);
  Console.CursorColumn := 0;
  Console.CursorRow := 0;
end;

{ --- Characters --------------------------------------------------------------- }

{ The glyph of CodePoint (a question mark if the font lacks it). }
function GlyphIndexOf(CodePoint: LongWord): Integer;
var
  Low: Integer;
  High: Integer;
  Middle: Integer;
begin
  Low := 0;
  High := ConsoleFontGlyphCount - 1;
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    if ConsoleFontCodePoints[Middle] = CodePoint then
      Exit(Middle);
    if ConsoleFontCodePoints[Middle] < CodePoint then
      Low := Middle + 1
    else
      High := Middle - 1;
  end;
  if CodePoint = Ord('?') then
    Exit(0);
  Result := GlyphIndexOf(Ord('?'));
end;

procedure DrawGlyph(CodePoint: LongWord; Column, Row: LongWord);
var
  GlyphIndex: Integer;
  PixelLeft: LongWord;
  PixelTop: LongWord;
  GlyphRow: Integer;
  GlyphColumn: Integer;
  RowBits: Byte;
  Line: array[0..ConsoleFontWidth - 1] of LongWord;
begin
  GlyphIndex := GlyphIndexOf(CodePoint);
  PixelLeft := ConsoleMargin + Column * ConsoleFontWidth;
  PixelTop := ConsoleMargin + Row * ConsoleFontHeight;
  for GlyphRow := 0 to ConsoleFontHeight - 1 do
  begin
    RowBits := ConsoleFontGlyphs[GlyphIndex, GlyphRow];
    for GlyphColumn := 0 to ConsoleFontWidth - 1 do
      if (RowBits and ($80 shr GlyphColumn)) <> 0 then
        Line[GlyphColumn] := Console.ForegroundPixel
      else
        Line[GlyphColumn] := Console.BackgroundPixel;
    PutPixels(PixelTop + LongWord(GlyphRow), PixelLeft, @Line[0], ConsoleFontWidth);
  end;
end;

procedure ClearCells(Row, FirstColumn, LastColumn: LongWord);
begin
  if FirstColumn > LastColumn then
    Exit;
  FillRectangle(ConsoleMargin + FirstColumn * ConsoleFontWidth, ConsoleMargin + Row * ConsoleFontHeight,
    (LastColumn - FirstColumn + 1) * ConsoleFontWidth, ConsoleFontHeight, Console.BackgroundPixel);
end;

procedure ScrollUpOneRow;
var
  TextAreaTop: LongWord;
  ScanLinesToMove: LongWord;
  PixelRow: LongWord;
begin
  TextAreaTop := ConsoleMargin;
  ScanLinesToMove := (Console.Rows - 1) * ConsoleFontHeight;
  if Console.Shadow <> nil then
  begin
    { Moved in ordinary memory, then written out: video memory is slow to
      read. }
    MoveMemory(ShadowLineAddress(TextAreaTop), ShadowLineAddress(TextAreaTop + ConsoleFontHeight),
      QWord(ScanLinesToMove) * Console.WidthInPixels * SizeOf(LongWord));
    if not Console.DrawingSuspended then
      for PixelRow := TextAreaTop to TextAreaTop + ScanLinesToMove - 1 do
        WriteScanLine(PixelRow, 0, ShadowLineAddress(PixelRow), Console.WidthInPixels);
  end
  else if not Console.DrawingSuspended then
    MoveMemory(ScanLineAddress(TextAreaTop), ScanLineAddress(TextAreaTop + ConsoleFontHeight),
      QWord(ScanLinesToMove) * Console.PixelsPerScanLine * Console.BytesPerPixel);
  FillRectangle(0, TextAreaTop + ScanLinesToMove, Console.WidthInPixels,
    ConsoleFontHeight, Console.BackgroundPixel);
end;

procedure AdvanceToNextLine;
begin
  Console.CursorColumn := 0;
  if Console.CursorRow + 1 < Console.Rows then
    Inc(Console.CursorRow)
  else
    ScrollUpOneRow;
end;

procedure PutCodePoint(CodePoint: LongWord);
begin
  if Console.CursorColumn >= Console.Columns then
    AdvanceToNextLine;
  DrawGlyph(CodePoint, Console.CursorColumn, Console.CursorRow);
  Inc(Console.CursorColumn);
end;

{ --- Escape sequences ----------------------------------------------------------- }

function Parameter(Index: Integer; Default: LongWord): LongWord;
begin
  if (Index < Console.ParameterCount) and (Console.Parameters[Index] <> 0) then
    Result := Console.Parameters[Index]
  else
    Result := Default;
end;

function PaletteColor(Index: LongWord; Bright: Boolean): LongWord;
const
  Normal: array[0..7] of TColor = (
    (Red: $00; Green: $00; Blue: $00), (Red: $C0; Green: $30; Blue: $30),
    (Red: $40; Green: $B0; Blue: $40), (Red: $C0; Green: $A0; Blue: $30),
    (Red: $40; Green: $60; Blue: $D0), (Red: $B0; Green: $40; Blue: $B0),
    (Red: $40; Green: $B0; Blue: $C0), (Red: $C0; Green: $C0; Blue: $C0));
  Light: array[0..7] of TColor = (
    (Red: $60; Green: $60; Blue: $60), (Red: $F0; Green: $50; Blue: $50),
    (Red: $60; Green: $D0; Blue: $60), (Red: $F0; Green: $D0; Blue: $40),
    (Red: $70; Green: $90; Blue: $F0), (Red: $E0; Green: $70; Blue: $E0),
    (Red: $40; Green: $D0; Blue: $E0), (Red: $FF; Green: $FF; Blue: $FF));
begin
  if Bright then
    Result := EncodePixel(Light[Index and 7])
  else
    Result := EncodePixel(Normal[Index and 7]);
end;

procedure SelectGraphicRendition;
var
  Index: Integer;
  Value: LongWord;
begin
  if Console.ParameterCount = 0 then
    Console.ParameterCount := 1;
  for Index := 0 to Console.ParameterCount - 1 do
  begin
    Value := Console.Parameters[Index];
    case Value of
      0:
        begin
          Console.ForegroundPixel := Console.DefaultForegroundPixel;
          Console.BackgroundPixel := Console.DefaultBackgroundPixel;
        end;
      30..37: Console.ForegroundPixel := PaletteColor(Value - 30, False);
      39: Console.ForegroundPixel := Console.DefaultForegroundPixel;
      40..47: Console.BackgroundPixel := PaletteColor(Value - 40, False);
      49: Console.BackgroundPixel := Console.DefaultBackgroundPixel;
      90..97: Console.ForegroundPixel := PaletteColor(Value - 90, True);
      100..107: Console.BackgroundPixel := PaletteColor(Value - 100, True);
    end;
  end;
end;

{ Carries out ESC [ parameters Final: cursor movement and positioning,
  erasing, colours. Anything else is ignored. }
procedure RunControlSequence(Final: Char);
var
  Count: LongWord;
begin
  case Final of
    'A':
      begin
        Count := Parameter(0, 1);
        if Count > Console.CursorRow then
          Count := Console.CursorRow;
        Console.CursorRow := Console.CursorRow - Count;
      end;
    'B':
      begin
        Console.CursorRow := Console.CursorRow + Parameter(0, 1);
        if Console.CursorRow >= Console.Rows then
          Console.CursorRow := Console.Rows - 1;
      end;
    'C':
      begin
        Console.CursorColumn := Console.CursorColumn + Parameter(0, 1);
        if Console.CursorColumn >= Console.Columns then
          Console.CursorColumn := Console.Columns - 1;
      end;
    'D':
      begin
        Count := Parameter(0, 1);
        if Count > Console.CursorColumn then
          Count := Console.CursorColumn;
        Console.CursorColumn := Console.CursorColumn - Count;
      end;
    'G':
      Console.CursorColumn := Parameter(0, 1) - 1;
    'H', 'f':
      begin
        Console.CursorRow := Parameter(0, 1) - 1;
        Console.CursorColumn := Parameter(1, 1) - 1;
      end;
    'K':
      case Parameter(0, 0) of
        0: ClearCells(Console.CursorRow, Console.CursorColumn, Console.Columns - 1);
        1: ClearCells(Console.CursorRow, 0, Console.CursorColumn);
        2: ClearCells(Console.CursorRow, 0, Console.Columns - 1);
      end;
    'J':
      if Parameter(0, 0) = 2 then
        ConsoleClearScreen
      else if Parameter(0, 0) = 0 then
      begin
        ClearCells(Console.CursorRow, Console.CursorColumn, Console.Columns - 1);
        if Console.CursorRow + 1 < Console.Rows then
          FillRectangle(0, ConsoleMargin + (Console.CursorRow + 1) * ConsoleFontHeight, Console.WidthInPixels,
            (Console.Rows - Console.CursorRow - 1) * ConsoleFontHeight, Console.BackgroundPixel);
      end;
    'm':
      SelectGraphicRendition;
  end;
  if Console.CursorRow >= Console.Rows then
    Console.CursorRow := Console.Rows - 1;
  if Console.CursorColumn >= Console.Columns then
    Console.CursorColumn := Console.Columns - 1;
end;

{ Takes one byte of an escape sequence (after its ESC). }
procedure TakeSequenceByte(Character: Char);
begin
  if Console.State = InputEscape then
  begin
    if Character = '[' then
    begin
      Console.State := InputControlSequence;
      Console.ParameterCount := 0;
      FillMemory(@Console.Parameters[0], SizeOf(Console.Parameters), 0);
    end
    else
      Console.State := InputNormal;
    Exit;
  end;
  case Character of
    '0'..'9':
      begin
        if Console.ParameterCount = 0 then
          Console.ParameterCount := 1;
        if Console.ParameterCount <= MaximumParameters then
          Console.Parameters[Console.ParameterCount - 1] :=
            Console.Parameters[Console.ParameterCount - 1] * 10 + LongWord(Ord(Character) - Ord('0'));
      end;
    ';':
      begin
        if Console.ParameterCount = 0 then
          Console.ParameterCount := 1;
        if Console.ParameterCount < MaximumParameters then
          Inc(Console.ParameterCount);
      end;
    '?', ' ', '<'..'>':
      ; { private markers and intermediates }
    '@'..'~':
      begin
        RunControlSequence(Character);
        Console.State := InputNormal;
      end;
  else
    Console.State := InputNormal;
  end;
end;

{ --- Bytes ------------------------------------------------------------------------- }

procedure TakeControlCharacter(Character: Char);
begin
  case Character of
    #10:
      AdvanceToNextLine;
    #13:
      Console.CursorColumn := 0;
    #9:
      repeat
        PutCodePoint(Ord(' '));
      until (Console.CursorColumn mod TabWidth) = 0;
    #8:
      if Console.CursorColumn > 0 then
        Dec(Console.CursorColumn);
    #27:
      Console.State := InputEscape;
  end;
end;

{ Decodes UTF-8: a complete character is drawn; a malformed one shows as
  a question mark. }
procedure TakeTextByte(Value: Byte);
begin
  if Console.PendingBytes > 0 then
  begin
    if (Value and $C0) = $80 then
    begin
      Console.PendingCodePoint := (Console.PendingCodePoint shl 6) or (Value and $3F);
      Dec(Console.PendingBytes);
      if Console.PendingBytes = 0 then
        PutCodePoint(Console.PendingCodePoint);
      Exit;
    end;
    Console.PendingBytes := 0;
    PutCodePoint(Ord('?'));
  end;
  if Value < $80 then
    PutCodePoint(Value)
  else if (Value and $E0) = $C0 then
  begin
    Console.PendingCodePoint := Value and $1F;
    Console.PendingBytes := 1;
  end
  else if (Value and $F0) = $E0 then
  begin
    Console.PendingCodePoint := Value and $0F;
    Console.PendingBytes := 2;
  end
  else if (Value and $F8) = $F0 then
  begin
    Console.PendingCodePoint := Value and $07;
    Console.PendingBytes := 3;
  end
  else
    PutCodePoint(Ord('?'));
end;

procedure ConsoleWriteCharacter(Character: Char);
begin
  if not Console.IsAvailable then
    Exit;
  if Console.State <> InputNormal then
    TakeSequenceByte(Character)
  else if Character < ' ' then
    TakeControlCharacter(Character)
  else if Character <> #127 then
    TakeTextByte(Byte(Character));
end;

end.
