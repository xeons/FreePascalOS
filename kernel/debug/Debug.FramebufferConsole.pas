{
  Text console drawn directly into the boot framebuffer.

  It needs nothing but the framebuffer address handed over by the loader,
  so it is available from the start of kernel initialization until a real
  display driver takes over. Callers are responsible for locking; the
  kernel debug output unit serializes access.
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

implementation

uses
  Runtime.Memory;

{$include Debug.ConsoleFont.inc}

const
  TabWidth = 8;
  ConsoleMargin = 8;

type
  TConsoleState = record
    IsAvailable: Boolean;
    Pixels: PLongWord;
    PixelsPerScanLine: LongWord;
    WidthInPixels: LongWord;
    HeightInPixels: LongWord;
    PixelFormat: LongWord;
    Columns: LongWord;
    Rows: LongWord;
    CursorColumn: LongWord;
    CursorRow: LongWord;
    ForegroundPixel: LongWord;
    BackgroundPixel: LongWord;
  end;

var
  Console: TConsoleState;

function EncodePixel(const Color: TColor): LongWord;
begin
  if Console.PixelFormat = PixelFormatRedGreenBlue then
    Result := LongWord(Color.Red) or (LongWord(Color.Green) shl 8) or (LongWord(Color.Blue) shl 16)
  else
    Result := LongWord(Color.Blue) or (LongWord(Color.Green) shl 8) or (LongWord(Color.Red) shl 16);
end;

function ScanLineAddress(PixelRow: LongWord): PLongWord;
begin
  Result := Console.Pixels + QWord(PixelRow) * Console.PixelsPerScanLine;
end;

procedure FillRectangle(Left, Top, Width, Height: LongWord; Pixel: LongWord);
var
  RowOffset: LongWord;
  ColumnOffset: LongWord;
  Line: PLongWord;
begin
  RowOffset := 0;
  while RowOffset < Height do
  begin
    Line := ScanLineAddress(Top + RowOffset);
    ColumnOffset := 0;
    while ColumnOffset < Width do
    begin
      Line[Left + ColumnOffset] := Pixel;
      Inc(ColumnOffset);
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

  Console.Pixels := PLongWord(FramebufferVirtualBase);
  Console.PixelsPerScanLine := Framebuffer.PixelsPerScanLine;
  Console.WidthInPixels := Framebuffer.Width;
  Console.HeightInPixels := Framebuffer.Height;
  Console.PixelFormat := Framebuffer.PixelFormat;
  Console.Columns := (Framebuffer.Width - 2 * ConsoleMargin) div ConsoleFontWidth;
  Console.Rows := (Framebuffer.Height - 2 * ConsoleMargin) div ConsoleFontHeight;
  Console.ForegroundPixel := EncodePixel(ColorLightGray);
  Console.BackgroundPixel := EncodePixel(ColorDarkBlue);
  Console.IsAvailable := True;

  ConsoleClearScreen;
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

procedure DrawGlyph(Character: Char; Column, Row: LongWord);
var
  GlyphIndex: Integer;
  PixelLeft: LongWord;
  PixelTop: LongWord;
  GlyphRow: Integer;
  GlyphColumn: Integer;
  RowBits: Byte;
  Line: PLongWord;
begin
  GlyphIndex := Ord(Character);
  if (GlyphIndex < ConsoleFontFirstCharacter) or (GlyphIndex > ConsoleFontLastCharacter) then
    GlyphIndex := Ord('?');

  PixelLeft := ConsoleMargin + Column * ConsoleFontWidth;
  PixelTop := ConsoleMargin + Row * ConsoleFontHeight;

  for GlyphRow := 0 to ConsoleFontHeight - 1 do
  begin
    RowBits := ConsoleFontGlyphs[GlyphIndex, GlyphRow];
    Line := ScanLineAddress(PixelTop + LongWord(GlyphRow));
    for GlyphColumn := 0 to ConsoleFontWidth - 1 do
    begin
      if (RowBits and ($80 shr GlyphColumn)) <> 0 then
        Line[PixelLeft + LongWord(GlyphColumn)] := Console.ForegroundPixel
      else
        Line[PixelLeft + LongWord(GlyphColumn)] := Console.BackgroundPixel;
    end;
  end;
end;

procedure ScrollUpOneRow;
var
  TextAreaTop: LongWord;
  BytesPerScanLine: QWord;
  ScanLinesToMove: LongWord;
begin
  TextAreaTop := ConsoleMargin;
  BytesPerScanLine := QWord(Console.PixelsPerScanLine) * SizeOf(LongWord);
  ScanLinesToMove := (Console.Rows - 1) * ConsoleFontHeight;

  MoveMemory(ScanLineAddress(TextAreaTop),
    ScanLineAddress(TextAreaTop + ConsoleFontHeight),
    ScanLinesToMove * BytesPerScanLine);

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

procedure ConsoleWriteCharacter(Character: Char);
begin
  if not Console.IsAvailable then
    Exit;

  case Character of
    #10:
      AdvanceToNextLine;
    #13:
      Console.CursorColumn := 0;
    #9:
      begin
        repeat
          ConsoleWriteCharacter(' ');
        until (Console.CursorColumn mod TabWidth) = 0;
      end;
    #8:
      begin
        if Console.CursorColumn > 0 then
          Dec(Console.CursorColumn);
      end;
  else
    begin
      if Console.CursorColumn >= Console.Columns then
        AdvanceToNextLine;
      DrawGlyph(Character, Console.CursorColumn, Console.CursorRow);
      Inc(Console.CursorColumn);
    end;
  end;
end;

end.
