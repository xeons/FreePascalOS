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
  wintest - a window on the display server, for testing it

  wintest [-t TITLE] [-x LEFT] [-y TOP] [-w WIDTH] [-h HEIGHT] [-c RRGGBB] [-b]

  Connects to the display server and shows a framed, resizable window
  (position and size in logical units, 1/96 inch) filled with a colour,
  with its title written in it. With -b the pointer is a text beam over
  the left half of it (a pointer area). Prints what happens to it, a
  line each:

    created N              shown as window N
    active 1 / active 0    got or lost the keyboard
    button B press X Y     a button on it (surface pixels)
    key 0xCODE C           a key pressed (its character, if any)
    resized W H            given a new size (it draws itself again)
    moved L T              its place on the desktop (logical units)
    scale P D              its scale (percent) and DPI changed (it moved
                           to another display, or its display changed):
                           it draws itself again at the same logical size
    close                  its close button was pressed: it ends

  Talks the protocol directly (Windowing.Protocol).
}
program WinTest;

{$mode objfpc}

uses
  Abi.SystemCalls,
  Sys.Format,
  Sys.Objects,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Drawing.Canvas,
  Drawing.Bevels,
  Font.Faces,
  Font.Text,
  Font.Files,
  Windowing.Protocol;

const
  Usage: PChar = 'Usage: wintest [-t TITLE] [-x LEFT] [-y TOP] [-w WIDTH] [-h HEIGHT] [-c RRGGBB] [-b]'#10 +
    'Show a window on the display server and print what happens to it.'#10 +
    '  -b  the pointer is a text beam over the left half of the window'#10;
  OptionTitle = 1;
  OptionLeft = 2;
  OptionTop = 3;
  OptionWidth = 4;
  OptionHeight = 5;
  OptionColor = 6;
  OptionBeam = 7;
  BeamArea = 1;
  ConnectTries = 50;
  ReplyTimeout = 5000;

var
  Channel: Int64;
  Scale: LongWord;
  Dpi: LongWord;
  WindowId: LongWord;
  Title: PChar;
  Color: TColor;
  Fonts: TFontSet;
  TextFace: PFontFace;
  FontsLoaded: Boolean;
  Section: Int64;
  Pixels: Pointer;
  SurfaceWidth: LongInt;
  SurfaceHeight: LongInt;
  BeamOverLeftHalf: Boolean;

procedure Say(Format: PChar; const Arguments: array of TFormatArgument);
begin
  WriteFormatted(StandardOutput, Format, Arguments);
  FlushStream(StandardOutput);
end;

procedure Send(var Message: TWindowMessage; Handle: Int64);
begin
  if Handle >= 0 then
    SendMessage(Channel, @Message, SizeOf(Message), [Handle])
  else
    SendMessage(Channel, @Message, SizeOf(Message), []);
end;

{ The next message from the server (waiting up to Timeout). }
function Receive(out Message: TWindowMessage; Timeout: Int64): Boolean;
var
  Handles: array[0..0] of Int64;
  Length: QWord;
  HandleCount: QWord;
begin
  Result := (WaitForMessage(Channel, @Message, SizeOf(Message), Length, Handles, HandleCount, Timeout) = ErrorNone)
    and (Length = SizeOf(Message));
end;

{ A section of Width x Height pixels with the window's picture in it. }
function DrawSurface(Width, Height: LongInt): Int64;
var
  Surface: TSurface;
  Canvas: TCanvas;
begin
  Result := CreateSection(QWord(Width) * QWord(Height) * 4);
  if Result < 0 then
    Exit;
  if Pixels <> nil then
    UnmapSection(Pixels);
  Pixels := MapSection(Result, 0, QWord(Width) * QWord(Height) * 4);
  SurfaceWidth := Width;
  SurfaceHeight := Height;
  Surface := SurfaceOnPixels(Pixels, Width, Height, Width * 4);
  BeginCanvas(Canvas, Surface);
  FillRectangle(Canvas, SurfaceBounds(Surface), Color);
  DrawEdge(Canvas, SurfaceBounds(Surface), $FF000000, $FFFFFFFF);
  if TextFace <> nil then
    DrawText(Canvas, TextFace^, LogicalToPixels(8, Scale), LogicalToPixels(8, Scale), Title, $FF000000);
end;

procedure Connect;
var
  Attempt: Integer;
  Message: TWindowMessage;
begin
  for Attempt := 1 to ConnectTries do
  begin
    Channel := ConnectPort(WindowingPortName);
    if Channel >= 0 then
      Break;
    SleepMilliseconds(100);
  end;
  if Channel < 0 then
    Fail(1, 'no display server', []);
  Message := NewMessage(RequestHello, 0);
  Message.Value := ProtocolVersion;
  Send(Message, -1);
  if not Receive(Message, ReplyTimeout) or (Message.Kind <> EventWelcome) then
    Fail(1, 'the display server did not answer', []);
  Dpi := LongWord(Message.Value);
  Scale := Message.Code;
end;

{ The text beam over the left half of the surface (it follows a new
  size). }
procedure SetBeamArea;
var
  Request: TWindowMessage;
begin
  if not BeamOverLeftHalf then
    Exit;
  Request := NewMessage(RequestSetPointerShape, WindowId);
  Request.Code := PointerTextBeam;
  Request.Value := BeamArea;
  Request.Width := SurfaceWidth div 2;
  Request.Height := SurfaceHeight;
  Send(Request, -1);
end;

{ Gives the window a new surface of Width x Height pixels. }
procedure ReplaceSurface(Width, Height: LongInt);
var
  Request: TWindowMessage;
  NewSection: Int64;
begin
  NewSection := DrawSurface(Width, Height);
  Request := NewMessage(RequestSetSurface, WindowId);
  Request.SurfaceWidth := SurfaceWidth;
  Request.SurfaceHeight := SurfaceHeight;
  Send(Request, NewSection);
  CloseHandle(Section);
  Section := NewSection;
  SetBeamArea;
end;

{ The same logical size at the new scale; the text at the new DPI. }
procedure TakeNewScale(NewScale, NewDpi: LongWord);
var
  LogicalWidth: LongInt;
  LogicalHeight: LongInt;
begin
  LogicalWidth := PixelsToLogical(SurfaceWidth, Scale);
  LogicalHeight := PixelsToLogical(SurfaceHeight, Scale);
  Scale := NewScale;
  Dpi := NewDpi;
  if FontsLoaded then
    TextFace := SelectFace(Fonts, 90, Dpi, False);
  ReplaceSurface(LogicalToPixels(LogicalWidth, Scale), LogicalToPixels(LogicalHeight, Scale));
  Say('scale %u %u'#10, [ArgumentUnsigned(Scale), ArgumentUnsigned(Dpi)]);
end;

procedure HandleEvents;
var
  Message: TWindowMessage;
  Request: TWindowMessage;
begin
  while Receive(Message, InfiniteWait) do
    case Message.Kind of
      EventActivated:
        Say('active %d'#10, [ArgumentNumber(Message.Value)]);
      EventPointerButton:
        if Message.Value <> 0 then
          Say('button %u press %d %d'#10, [ArgumentUnsigned(Message.Code), ArgumentNumber(Message.Left),
            ArgumentNumber(Message.Top)]);
      EventKey:
        if Message.Value <> 0 then
          if (Message.Character >= 32) and (Message.Character < 127) then
            Say('key 0x%X %c'#10, [ArgumentUnsigned(Message.Code), ArgumentCharacter(Char(Message.Character))])
          else
            Say('key 0x%X'#10, [ArgumentUnsigned(Message.Code)]);
      EventResized:
        begin
          ReplaceSurface(Message.SurfaceWidth, Message.SurfaceHeight);
          Say('resized %d %d'#10, [ArgumentNumber(SurfaceWidth), ArgumentNumber(SurfaceHeight)]);
        end;
      EventMoved:
        Say('moved %d %d'#10, [ArgumentNumber(Message.Left), ArgumentNumber(Message.Top)]);
      EventScaleChanged:
        { For window 0 it is about the first display, not this window. }
        if Message.Window = WindowId then
          TakeNewScale(Message.Code, LongWord(Message.Value));
      EventCloseRequested:
        begin
          Say('close'#10, []);
          Request := NewMessage(RequestDestroyWindow, WindowId);
          Send(Request, -1);
          Exit;
        end;
    end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  OptionValue: PChar;
  Number: Int64;
  Left: LongInt;
  Top: LongInt;
  Width: LongInt;
  Height: LongInt;
  ColorValue: QWord;
  Message: TWindowMessage;
begin
  Title := 'Test window';
  Left := 100;
  Top := 100;
  Width := 300;
  Height := 200;
  Color := $FFF0E8D0;
  BeginOptions(Parser, [OptionDefinition('t', 'title', True, OptionTitle), OptionDefinition('x', 'left', True, OptionLeft),
    OptionDefinition('y', 'top', True, OptionTop), OptionDefinition('w', 'width', True, OptionWidth),
    OptionDefinition('h', 'height', True, OptionHeight), OptionDefinition('c', 'color', True, OptionColor),
    OptionDefinition('b', 'beam', False, OptionBeam)], Usage);
  while NextOption(Parser, Code, OptionValue) do
    case Code of
      OptionTitle:
        Title := OptionValue;
      OptionBeam:
        BeamOverLeftHalf := True;
      OptionColor:
        begin
          if not ParseHexadecimal(OptionValue, ColorValue) or (ColorValue > $FFFFFF) then
            FailWithUsageHint('the colour must be six hexadecimal digits (RRGGBB)', []);
          Color := $FF000000 or TColor(ColorValue);
        end;
    else
      begin
        if not ParseInteger(OptionValue, Number) then
          FailWithUsageHint('%s is not a number', [ArgumentText(OptionValue)]);
        case Code of
          OptionLeft: Left := Number;
          OptionTop: Top := Number;
          OptionWidth: Width := Number;
          OptionHeight: Height := Number;
        end;
      end;
    end;
  Connect;
  FontsLoaded := LoadFontFamily(DejaVuSansFamily, Fonts);
  if FontsLoaded then
    TextFace := SelectFace(Fonts, 90, Dpi, False);
  Section := DrawSurface(LogicalToPixels(Width, Scale), LogicalToPixels(Height, Scale));
  if Section < 0 then
    Fail(1, 'no memory for the window', []);
  Message := NewMessage(RequestCreateWindow, 0);
  Message.Left := Left;
  Message.Top := Top;
  Message.SurfaceWidth := SurfaceWidth;
  Message.SurfaceHeight := SurfaceHeight;
  Message.Flags := WindowFramed or WindowResizable;
  SetMessageText(Message, Title);
  Send(Message, Section);
  if not Receive(Message, ReplyTimeout) or (Message.Kind <> EventWindowCreated) then
    Fail(1, 'the window was not created', []);
  WindowId := Message.Window;
  Say('created %u'#10, [ArgumentUnsigned(WindowId)]);
  SetBeamArea;
  Message := NewMessage(RequestShowWindow, WindowId);
  Message.Value := 1;
  Send(Message, -1);
  HandleEvents;
end.
