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
  The terminal as a control: a grid of character cells drawn in the
  theme's monospaced face (Terminus) at TerminalPointTenths, so a cell is
  the same size on any display, with a scroll bar for the scrollback.

  Its size decides the rows and columns: when they change it resizes
  the emulator's screens and says so (OnGridResized), for the
  pseudo-terminal to be told. Keys become the bytes a terminal sends
  (Terminal.Keys) and go to OnInput; so does pasted text, its line ends
  as carriage returns (what Enter sends).

  The mouse selects text (by cells, in reading order); Ctrl+Shift+C
  copies it, Ctrl+Shift+V and Shift+Insert paste, and a right click
  shows Copy, Paste and Select All in the edit commands' context menu
  (Controls.EditCommands). The wheel, Shift+Page Up and Shift+Page Down
  scroll back through what scrolled off the top; typing goes back to
  the bottom. A bell flashes the view (Flash).
}
unit Terminal.View;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Font.Faces,
  Windowing.Messages,
  Controls.Base,
  Controls.ScrollBar,
  Controls.EditCommands,
  Terminal.Cells,
  Terminal.Emulator,
  Terminal.Selection;

const
  DefaultTerminalPointTenths = 110;

var
  { The text's size, in tenths of a point: the terminal sets it from the
    user's settings before it makes its window. }
  TerminalPointTenths: LongWord = DefaultTerminalPointTenths;

type
  TInputEvent = procedure(const Bytes: string) of object;
  TGridEvent = procedure(Rows, Columns: LongInt) of object;

  TTerminalView = class(TControl)
  private
    FEmulator: TTerminalEmulator;
    FScrollBar: TScrollBar;
    { Lines scrolled back from the newest (0: following the output). }
    FScrollOffset: LongInt;
    FSeenLinesScrolledOff: QWord;
    FSelection: TTerminalSelection;
    FSelecting: Boolean;
    FFlashing: Boolean;
    { The faces and cell size at the window's DPI (PickFaces). }
    FRegularFace: PFontFace;
    FBoldFace: PFontFace;
    FCellWidth: LongInt;
    FCellHeight: LongInt;
    FOnInput: TInputEvent;
    FOnGridResized: TGridEvent;
    procedure PickFaces;
    function CellFace(Bold: Boolean): PFontFace;
    function Margin: LongInt;
    function TextAreaWidth: LongInt;
    function FirstShownLine: LongInt;
    function PlaceAt(X, Y: LongInt): TTextPlace;
    procedure SetScrollOffset(Value: LongInt);
    procedure UpdateScrollBar;
    procedure SendInput(const Bytes: string);
    procedure CopySelection;
    procedure PasteClipboard;
    procedure SelectAll;
    procedure RunEditCommand(Command: TEditCommand);
    procedure PaintCell(const Canvas: TCanvas; const Cell: TCell; X, Y: LongInt; Selected, IsCursor: Boolean);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure Wheel(Steps: LongInt); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure FocusChanged; override;
    procedure Layout; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { Output from the programs: shown, following it unless scrolled
      back. }
    procedure ShowOutput(Data: PByte; Count: LongInt);
    { The view's pixel size that holds Rows by Columns cells (with the
      scroll bar), at the scale now selected. }
    procedure SizeForGrid(Rows, Columns: LongInt; out Width, Height: LongInt);
    procedure Flash(On: Boolean);
    { The size of a cell in pixels, at the scale now selected. }
    procedure CellSize(out Width, Height: LongInt);
    property Emulator: TTerminalEmulator read FEmulator;
    property OnInput: TInputEvent read FOnInput write FOnInput;
    property OnGridResized: TGridEvent read FOnGridResized write FOnGridResized;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Font.Text,
  Windowing.Protocol,
  Windowing.Theme,
  Windowing.Connection,
  Windowing.Fonts,
  Controls.Keys,
  Controls.Clipboard,
  Terminal.Screen,
  Terminal.Keys;

const
  InitialRows = 25;
  InitialColumns = 80;
  WheelLines = 3;

constructor TTerminalView.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  PointerShape := PointerTextBeam;
  FEmulator := TTerminalEmulator.Create(InitialRows, InitialColumns);
  FScrollBar := TScrollBar.Create(Self);
  ClearSelection(FSelection);
end;

destructor TTerminalView.Destroy;
begin
  FEmulator.Free;
  inherited Destroy;
end;

{ Picked again whenever the view is laid out or painted: the window may
  have moved to a display of another DPI. }
procedure TTerminalView.PickFaces;
begin
  FRegularFace := FixedFontFace(TerminalPointTenths, False);
  FBoldFace := FixedFontFace(TerminalPointTenths, True);
  FCellWidth := 8;
  FCellHeight := 16;
  if FRegularFace <> nil then
  begin
    FCellWidth := FRegularFace^.Width;
    FCellHeight := FRegularFace^.Height;
  end;
  if FCellWidth < 1 then
    FCellWidth := 1;
  if FCellHeight < 1 then
    FCellHeight := 1;
end;

function TTerminalView.CellFace(Bold: Boolean): PFontFace;
begin
  if Bold and (FBoldFace <> nil) then
    Result := FBoldFace
  else
    Result := FRegularFace;
end;

function TTerminalView.Margin: LongInt;
begin
  Result := Scaled(2);
end;

function TTerminalView.TextAreaWidth: LongInt;
begin
  Result := RectangleWidth(PixelBounds) - Scaled(Theme.ScrollBarWidth);
end;

procedure TTerminalView.SizeForGrid(Rows, Columns: LongInt; out Width, Height: LongInt);
begin
  PickFaces;
  Width := Columns * FCellWidth + 2 * Margin + Scaled(Theme.ScrollBarWidth);
  Height := Rows * FCellHeight + 2 * Margin;
end;

function TTerminalView.FirstShownLine: LongInt;
begin
  Result := FEmulator.Screen.ScrollbackCount - FScrollOffset;
end;

procedure TTerminalView.Layout;
var
  Rows: LongInt;
  Columns: LongInt;
  BarWidth: LongInt;
begin
  PickFaces;
  BarWidth := Scaled(Theme.ScrollBarWidth);
  FScrollBar.AssignBounds(Unscaled(RectangleWidth(PixelBounds) - BarWidth), 0, Unscaled(BarWidth),
    Unscaled(RectangleHeight(PixelBounds)));
  Rows := (RectangleHeight(PixelBounds) - 2 * Margin) div FCellHeight;
  Columns := (TextAreaWidth - 2 * Margin) div FCellWidth;
  if Rows < 1 then
    Rows := 1;
  if Columns < 2 then
    Columns := 2;
  if (Rows <> FEmulator.Screen.Rows) or (Columns <> FEmulator.Screen.Columns) then
  begin
    FEmulator.Resize(Rows, Columns);
    FSeenLinesScrolledOff := FEmulator.Screen.LinesScrolledOff;
    SetScrollOffset(FScrollOffset);
    if Assigned(FOnGridResized) then
      FOnGridResized(Rows, Columns);
  end;
  UpdateScrollBar;
  inherited Layout;
end;

procedure TTerminalView.UpdateScrollBar;
begin
  FScrollBar.SetRange(0, FEmulator.Screen.LineCount, FEmulator.Screen.Rows);
  FScrollBar.Position := FirstShownLine;
end;

procedure TTerminalView.SetScrollOffset(Value: LongInt);
begin
  if Value > FEmulator.Screen.ScrollbackCount then
    Value := FEmulator.Screen.ScrollbackCount;
  if Value < 0 then
    Value := 0;
  if Value = FScrollOffset then
    Exit;
  FScrollOffset := Value;
  UpdateScrollBar;
  Invalidate;
end;

procedure TTerminalView.ReceiveMessage(var Message: TPostedMessage);
begin
  if (Message.Code = MessageNotify) and (TControl(Message.Parameter1) = FScrollBar) then
  begin
    if (Message.Parameter2 = NotifyChanged) and (FScrollBar.Position <> FirstShownLine) then
      SetScrollOffset(FEmulator.Screen.ScrollbackCount - FScrollBar.Position);
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

procedure TTerminalView.ShowOutput(Data: PByte; Count: LongInt);
var
  Added: QWord;
begin
  FEmulator.Feed(Data, Count);
  { Scrolled back: the lines shown stay where they are in the text. }
  Added := FEmulator.Screen.LinesScrolledOff - FSeenLinesScrolledOff;
  FSeenLinesScrolledOff := FEmulator.Screen.LinesScrolledOff;
  if FScrollOffset > 0 then
  begin
    FScrollOffset := FScrollOffset + LongInt(Added);
    if FScrollOffset > FEmulator.Screen.ScrollbackCount then
      FScrollOffset := FEmulator.Screen.ScrollbackCount;
  end;
  UpdateScrollBar;
  Invalidate;
end;

procedure TTerminalView.CellSize(out Width, Height: LongInt);
begin
  PickFaces;
  Width := FCellWidth;
  Height := FCellHeight;
end;

procedure TTerminalView.Flash(On: Boolean);
begin
  FFlashing := On;
  Invalidate;
end;

procedure TTerminalView.FocusChanged;
begin
  inherited FocusChanged;
  Invalidate;
end;

{ --- Input -------------------------------------------------------------- }

procedure TTerminalView.SendInput(const Bytes: string);
begin
  SetScrollOffset(0);
  if Assigned(FOnInput) then
    FOnInput(Bytes);
end;

procedure TTerminalView.CopySelection;
begin
  if not SelectionIsEmpty(FSelection) then
    SetClipboardText(SelectedText(FSelection, FEmulator.Screen));
end;

{ Line ends become carriage returns, as if Enter were pressed. }
procedure TTerminalView.PasteClipboard;
var
  Pasted: string;
  Sent: string;
  Index: LongInt;
begin
  if not ClipboardHasText then
    Exit;
  Pasted := ClipboardText;
  Sent := '';
  Index := 1;
  while Index <= Length(Pasted) do
  begin
    if (Pasted[Index] = #13) and (Index < Length(Pasted)) and (Pasted[Index + 1] = #10) then
      Inc(Index);
    if Pasted[Index] = #10 then
      Sent := Sent + #13
    else
      Sent := Sent + Pasted[Index];
    Inc(Index);
  end;
  SendInput(Sent);
end;

procedure TTerminalView.SelectAll;
var
  Screen: TTerminalScreen;
begin
  Screen := FEmulator.Screen;
  FSelection.Anchor := MakeTextPlace(AbsoluteLineOf(Screen, 0), 0);
  FSelection.Extent := MakeTextPlace(AbsoluteLineOf(Screen, Screen.LineCount - 1), Screen.Columns);
  Invalidate;
end;

procedure TTerminalView.RunEditCommand(Command: TEditCommand);
begin
  case Command of
    EditCommandCopy: CopySelection;
    EditCommandPaste: PasteClipboard;
    EditCommandSelectAll: SelectAll;
  end;
end;

function TTerminalView.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Held: LongWord;
  Sequence: string;
begin
  Result := True;
  Held := Modifiers and (ModifierShift or ModifierControl or ModifierAlt);
  if (Held = (ModifierControl or ModifierShift)) and (Code = KeyC) then
    CopySelection
  else if ((Held = (ModifierControl or ModifierShift)) and (Code = KeyV)) or
          ((Held = ModifierShift) and (Code = KeyInsert)) then
    PasteClipboard
  else if (Held = ModifierShift) and (Code = KeyPageUp) then
    SetScrollOffset(FScrollOffset + FEmulator.Screen.Rows - 1)
  else if (Held = ModifierShift) and (Code = KeyPageDown) then
    SetScrollOffset(FScrollOffset - FEmulator.Screen.Rows + 1)
  else if KeySequence(Code, Character, Modifiers, Sequence) then
    SendInput(Sequence)
  else
    Result := False;
end;

{ --- The mouse ---------------------------------------------------------- }

{ The column boundary nearest to X on the line under Y. }
function TTerminalView.PlaceAt(X, Y: LongInt): TTextPlace;
var
  Row: LongInt;
  Column: LongInt;
begin
  Row := (Y - Margin) div FCellHeight;
  if Y < Margin then
    Row := 0;
  if Row >= FEmulator.Screen.Rows then
    Row := FEmulator.Screen.Rows - 1;
  Column := (X - Margin + FCellWidth div 2) div FCellWidth;
  if Column < 0 then
    Column := 0;
  if Column > FEmulator.Screen.Columns then
    Column := FEmulator.Screen.Columns;
  Result := MakeTextPlace(AbsoluteLineOf(FEmulator.Screen, FirstShownLine + Row), Column);
end;

procedure TTerminalView.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if Button <> ButtonLeft then
    Exit;
  SetFocus;
  FSelecting := True;
  FSelection.Anchor := PlaceAt(X, Y);
  FSelection.Extent := FSelection.Anchor;
  Invalidate;
end;

procedure TTerminalView.PointerMove(X, Y: LongInt; Buttons: LongWord);
begin
  if not FSelecting then
    Exit;
  FSelection.Extent := PlaceAt(X, Y);
  Invalidate;
end;

procedure TTerminalView.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Commands: TEditCommands;
begin
  FSelecting := False;
  if Button <> ButtonRight then
    Exit;
  Commands := [EditCommandSelectAll];
  if not SelectionIsEmpty(FSelection) then
    Include(Commands, EditCommandCopy);
  if ClipboardHasText then
    Include(Commands, EditCommandPaste);
  { Opened as the button is let go, so the release does not land on the
    menu. }
  ShowEditMenu(Self, X, Y, Commands, @RunEditCommand);
end;

procedure TTerminalView.Wheel(Steps: LongInt);
begin
  SetScrollOffset(FScrollOffset + Steps * WheelLines);
end;

{ --- Painting ----------------------------------------------------------- }

procedure TTerminalView.PaintCell(const Canvas: TCanvas; const Cell: TCell; X, Y: LongInt;
  Selected, IsCursor: Boolean);
var
  Face: PFontFace;
  TextColor: TColor;
  BackgroundColor: TColor;
  Swapped: TColor;
begin
  CellColors(Cell, TextColor, BackgroundColor);
  if FFlashing then
  begin
    Swapped := TextColor;
    TextColor := BackgroundColor;
    BackgroundColor := Swapped;
  end;
  if Selected then
  begin
    TextColor := Theme.SelectionText;
    BackgroundColor := Theme.Selection;
  end;
  { A block cursor while the view has the focus: the cell's colours
    swapped. }
  if IsCursor and Focused then
  begin
    Swapped := TextColor;
    TextColor := BackgroundColor;
    BackgroundColor := Swapped;
  end;
  if BackgroundColor <> DefaultBackgroundColor then
    FillRectangle(Canvas, MakeRectangle(X, Y, FCellWidth, FCellHeight), BackgroundColor);
  Face := CellFace((Cell.Attributes and AttributeBold) <> 0);
  if (Face <> nil) and (Cell.CodePoint > 32) then
    DrawCharacter(Canvas, Face^, X, Y, Cell.CodePoint, TextColor);
  if ((Cell.Attributes and AttributeUnderline) <> 0) and (Face <> nil) then
    FillRectangle(Canvas, MakeRectangle(X, Y + Face^.UnderlineTop, FCellWidth, Scaled(1)), TextColor);
  { Without the focus, an outline. }
  if IsCursor and not Focused then
  begin
    FillRectangle(Canvas, MakeRectangle(X, Y, FCellWidth, 1), DefaultTextColor);
    FillRectangle(Canvas, MakeRectangle(X, Y + FCellHeight - 1, FCellWidth, 1), DefaultTextColor);
    FillRectangle(Canvas, MakeRectangle(X, Y, 1, FCellHeight), DefaultTextColor);
    FillRectangle(Canvas, MakeRectangle(X + FCellWidth - 1, Y, 1, FCellHeight), DefaultTextColor);
  end;
end;

procedure TTerminalView.Paint(var Canvas: TCanvas);
var
  Screen: TTerminalScreen;
  Background: TColor;
  Row: LongInt;
  Column: LongInt;
  Index: LongInt;
  Line: Int64;
  CursorIndex: LongInt;
  Inner: TCanvas;
begin
  PickFaces;
  Screen := FEmulator.Screen;
  Background := DefaultBackgroundColor;
  if FFlashing then
    Background := DefaultTextColor;
  FillRectangle(Canvas, MakeRectangle(0, 0, TextAreaWidth, RectangleHeight(PixelBounds)), Background);
  Inner := Canvas;
  NarrowCanvasClip(Inner, MakeRectangle(0, 0, TextAreaWidth, RectangleHeight(PixelBounds)));
  CursorIndex := -1;
  if Screen.CursorVisible then
    CursorIndex := Screen.ScrollbackCount + Screen.CursorRow;
  for Row := 0 to Screen.Rows - 1 do
  begin
    Index := FirstShownLine + Row;
    Line := AbsoluteLineOf(Screen, Index);
    for Column := 0 to Screen.Columns - 1 do
      PaintCell(Inner, Screen.CellAt(Index, Column), Margin + Column * FCellWidth, Margin + Row * FCellHeight,
        CellIsSelected(FSelection, Line, Column), (Index = CursorIndex) and (Column = Screen.CursorColumn));
  end;
end;

end.
