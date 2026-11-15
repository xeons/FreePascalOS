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
  The VT100/ANSI emulator: turns what programs write into changes of
  the screen (Terminal.Screen).

  Text is UTF-8. The control characters: bell (OnBell), backspace, tab,
  carriage return, and line feed (also vertical tab and form feed),
  which goes to the start of the next line, as the console does
  (programs here end lines with a line feed alone). Escape sequences:

    ESC 7 / ESC 8       save and restore the cursor (and the pen)
    ESC D, ESC E, ESC M index, next line, reverse index
    ESC c               reset
    ESC ( X and kin     character sets: ignored (always UTF-8)
    CSI n A B C D       cursor up, down, forward, back (also e and a)
    CSI n E F           down or up n lines, to the first column
    CSI n G, CSI n d    to column n, to row n
    CSI r ; c H         to row r, column c (also f)
    CSI n J, CSI n K    erase in the screen, in the line (0, 1, 2; J 3
                        empties the scrollback)
    CSI n L M           insert and delete lines
    CSI n @ P X         insert, delete and erase characters
    CSI n S T           scroll up and down
    CSI ... m           colours and attributes (Terminal.Rendition)
    CSI t ; b r         the scrolling region
    CSI s, CSI u        save and restore the cursor
    CSI 5 n, CSI 6 n    status and cursor position reports (OnReply)
    CSI c               "a VT100 with advanced video" (OnReply)
    CSI ? 25 h / l      show and hide the cursor
    CSI ? 7 h / l       wrap at the right edge or not
    CSI ? 47, 1047, 1049 h / l
                        the alternate screen (no scrollback), for
                        full-screen programs; 1049 saves the cursor too
    OSC 0 ; text BEL    the title (also OSC 2; ended by BEL or ESC \)

  Anything else is read and ignored, so unknown sequences do not show
  as text.
}
unit Terminal.Emulator;

{$mode objfpc}
{$H+}

interface

uses
  Terminal.Cells,
  Terminal.Screen,
  Terminal.Utf8Stream;

const
  MaximumParameters = 16;
  MaximumTitleLength = 256;

type
  TParserState = (StateGround, StateEscape, StateCharacterSet, StateControlSequence,
    StateOperatingSystemCommand, StateCommandEscape);

  TTitleEvent = procedure(const Title: string) of object;
  TReplyEvent = procedure(const Reply: string) of object;
  TBellEvent = procedure of object;

  TTerminalEmulator = class
  private
    FPrimary: TTerminalScreen;
    FAlternate: TTerminalScreen;
    FScreen: TTerminalScreen;
    FState: TParserState;
    FParameters: array[0..MaximumParameters - 1] of LongInt;
    FParameterCount: LongInt;
    FPrivateMarker: Char;
    FCommand: string;
    FUtf8: TUtf8Stream;
    FOnTitle: TTitleEvent;
    FOnReply: TReplyEvent;
    FOnBell: TBellEvent;
    procedure ProcessByte(Value: Byte);
    procedure ProcessGround(Value: Byte);
    procedure ProcessControl(Value: Byte);
    procedure ProcessEscape(Value: Byte);
    procedure ProcessControlSequence(Value: Byte);
    procedure ProcessCommand(Value: Byte);
    procedure BeginControlSequence;
    procedure DispatchControlSequence(Final: Char);
    procedure DispatchCommand;
    procedure SetModes(Enabled: Boolean);
    procedure UseAlternateScreen(Enabled, SaveCursor: Boolean);
    function Parameter(Index, Default: LongInt): LongInt;
    procedure Reply(const Text: string);
  public
    constructor Create(Rows, Columns: LongInt);
    destructor Destroy; override;
    procedure Feed(Data: PByte; Count: LongInt);
    procedure Resize(Rows, Columns: LongInt);
    procedure Reset;
    { The screen shown: the primary one or, for a full-screen program,
      the alternate one. }
    property Screen: TTerminalScreen read FScreen;
    property OnTitle: TTitleEvent read FOnTitle write FOnTitle;
    property OnReply: TReplyEvent read FOnReply write FOnReply;
    property OnBell: TBellEvent read FOnBell write FOnBell;
  end;

implementation

uses
  SysUtils,
  Terminal.Rendition;

const
  ControlBell = 7;
  ControlBackspace = 8;
  ControlTab = 9;
  ControlLineFeed = 10;
  ControlVerticalTab = 11;
  ControlFormFeed = 12;
  ControlCarriageReturn = 13;
  ControlCancel = 24;
  ControlSubstitute = 26;
  ControlEscape = 27;
  ControlDelete = 127;
  { The largest parameter kept: larger ones are as good as infinite. }
  LargestParameter = 65535;

constructor TTerminalEmulator.Create(Rows, Columns: LongInt);
begin
  inherited Create;
  FPrimary := TTerminalScreen.Create(Rows, Columns, DefaultScrollbackLines);
  FAlternate := TTerminalScreen.Create(Rows, Columns, 0);
  FScreen := FPrimary;
  FState := StateGround;
  ResetUtf8Stream(FUtf8);
end;

destructor TTerminalEmulator.Destroy;
begin
  FPrimary.Free;
  FAlternate.Free;
  inherited Destroy;
end;

procedure TTerminalEmulator.Resize(Rows, Columns: LongInt);
begin
  FPrimary.Resize(Rows, Columns);
  FAlternate.Resize(Rows, Columns);
end;

procedure TTerminalEmulator.Reset;
begin
  FScreen := FPrimary;
  FPrimary.Reset;
  FAlternate.Reset;
  FState := StateGround;
  ResetUtf8Stream(FUtf8);
end;

procedure TTerminalEmulator.Reply(const Text: string);
begin
  if Assigned(FOnReply) then
    FOnReply(Text);
end;

procedure TTerminalEmulator.Feed(Data: PByte; Count: LongInt);
var
  Index: LongInt;
begin
  for Index := 0 to Count - 1 do
    ProcessByte(Data[Index]);
end;

procedure TTerminalEmulator.ProcessByte(Value: Byte);
begin
  { Cancel and substitute end any sequence; escape starts a new one
    (except where it may end an operating system command). }
  if (Value = ControlCancel) or (Value = ControlSubstitute) then
  begin
    FState := StateGround;
    Exit;
  end;
  case FState of
    StateGround: ProcessGround(Value);
    StateEscape: ProcessEscape(Value);
    StateCharacterSet: FState := StateGround;
    StateControlSequence: ProcessControlSequence(Value);
    StateOperatingSystemCommand, StateCommandEscape: ProcessCommand(Value);
  end;
end;

procedure TTerminalEmulator.ProcessGround(Value: Byte);
var
  CodePoint: LongWord;
begin
  { A control character in the middle of a character breaks it. }
  if (Value < 32) or (Value = ControlDelete) then
  begin
    if Utf8StreamIsInside(FUtf8) then
    begin
      ResetUtf8Stream(FUtf8);
      FScreen.PutCharacter(ReplacementCharacter);
    end;
    ProcessControl(Value);
    Exit;
  end;
  case DecodeUtf8Byte(FUtf8, Value, CodePoint) of
    Utf8Character:
      FScreen.PutCharacter(CodePoint);
    Utf8BrokenBeforeByte:
      begin
        FScreen.PutCharacter(CodePoint);
        ProcessGround(Value);
      end;
  end;
end;

procedure TTerminalEmulator.ProcessControl(Value: Byte);
begin
  case Value of
    ControlBell:
      if Assigned(FOnBell) then
        FOnBell;
    ControlBackspace: FScreen.Backspace;
    ControlTab: FScreen.Tab;
    ControlLineFeed, ControlVerticalTab, ControlFormFeed:
      begin
        FScreen.LineFeed;
        FScreen.CarriageReturn;
      end;
    ControlCarriageReturn: FScreen.CarriageReturn;
    ControlEscape: FState := StateEscape;
  end;
end;

procedure TTerminalEmulator.ProcessEscape(Value: Byte);
begin
  FState := StateGround;
  case Char(Value) of
    '[': BeginControlSequence;
    ']':
      begin
        FCommand := '';
        FState := StateOperatingSystemCommand;
      end;
    '(', ')', '*', '+', '#', '%': FState := StateCharacterSet;
    '7': FScreen.SaveCursor;
    '8': FScreen.RestoreCursor;
    'D': FScreen.LineFeed;
    'E':
      begin
        FScreen.LineFeed;
        FScreen.CarriageReturn;
      end;
    'M': FScreen.ReverseLineFeed;
    'c': Reset;
  else
    { An escape again starts over; anything else is ignored. }
    if Value = ControlEscape then
      FState := StateEscape;
  end;
end;

procedure TTerminalEmulator.BeginControlSequence;
var
  Index: LongInt;
begin
  for Index := 0 to MaximumParameters - 1 do
    FParameters[Index] := 0;
  FParameterCount := 0;
  FPrivateMarker := #0;
  FState := StateControlSequence;
end;

procedure TTerminalEmulator.ProcessControlSequence(Value: Byte);
var
  Character: Char;
begin
  Character := Char(Value);
  if Value = ControlEscape then
  begin
    FState := StateEscape;
    Exit;
  end;
  { Control characters are carried out in the middle of a sequence. }
  if Value < 32 then
  begin
    ProcessControl(Value);
    Exit;
  end;
  case Character of
    '0'..'9':
      begin
        if FParameterCount = 0 then
          FParameterCount := 1;
        if FParameters[FParameterCount - 1] <= LargestParameter then
          FParameters[FParameterCount - 1] := FParameters[FParameterCount - 1] * 10 + Ord(Character) - Ord('0');
      end;
    ';', ':':
      begin
        if FParameterCount = 0 then
          FParameterCount := 1;
        if FParameterCount < MaximumParameters then
          Inc(FParameterCount);
      end;
    '<', '=', '>', '?':
      FPrivateMarker := Character;
    ' '..'/':
      { Intermediate bytes: none of the sequences carried out has one. };
    '@'..'~':
      begin
        FState := StateGround;
        DispatchControlSequence(Character);
      end;
  else
    FState := StateGround;
  end;
end;

{ Parameter Index, or Default when it is missing or 0. }
function TTerminalEmulator.Parameter(Index, Default: LongInt): LongInt;
begin
  if (Index >= FParameterCount) or (FParameters[Index] = 0) then
    Result := Default
  else
    Result := FParameters[Index];
end;

procedure TTerminalEmulator.UseAlternateScreen(Enabled, SaveCursor: Boolean);
begin
  if Enabled = (FScreen = FAlternate) then
    Exit;
  if Enabled then
  begin
    if SaveCursor then
      FPrimary.SaveCursor;
    FAlternate.Reset;
    FAlternate.Pen := FPrimary.Pen;
    FAlternate.MoveCursorTo(FPrimary.CursorRow, FPrimary.CursorColumn);
    FScreen := FAlternate;
  end
  else
  begin
    FScreen := FPrimary;
    if SaveCursor then
      FPrimary.RestoreCursor;
  end;
end;

procedure TTerminalEmulator.SetModes(Enabled: Boolean);
var
  Index: LongInt;
begin
  if FPrivateMarker <> '?' then
    Exit;
  for Index := 0 to FParameterCount - 1 do
    case FParameters[Index] of
      7: FScreen.AutoWrap := Enabled;
      25: FScreen.CursorVisible := Enabled;
      47, 1047: UseAlternateScreen(Enabled, False);
      1049: UseAlternateScreen(Enabled, True);
    end;
end;

procedure TTerminalEmulator.DispatchControlSequence(Final: Char);
var
  Row: LongInt;
  Column: LongInt;
  Pen: TCell;
begin
  Row := FScreen.CursorRow;
  Column := FScreen.CursorColumn;
  if FPrivateMarker <> #0 then
  begin
    case Final of
      'h': SetModes(True);
      'l': SetModes(False);
    end;
    Exit;
  end;
  case Final of
    'A': FScreen.MoveCursorTo(Row - Parameter(0, 1), Column);
    'B', 'e': FScreen.MoveCursorTo(Row + Parameter(0, 1), Column);
    'C', 'a': FScreen.MoveCursorTo(Row, Column + Parameter(0, 1));
    'D': FScreen.MoveCursorTo(Row, Column - Parameter(0, 1));
    'E': FScreen.MoveCursorTo(Row + Parameter(0, 1), 0);
    'F': FScreen.MoveCursorTo(Row - Parameter(0, 1), 0);
    'G', '`': FScreen.MoveCursorTo(Row, Parameter(0, 1) - 1);
    'd': FScreen.MoveCursorTo(Parameter(0, 1) - 1, Column);
    'H', 'f': FScreen.MoveCursorTo(Parameter(0, 1) - 1, Parameter(1, 1) - 1);
    'J': FScreen.EraseInDisplay(Parameter(0, 0));
    'K': FScreen.EraseInLine(Parameter(0, 0));
    'L': FScreen.InsertLines(Parameter(0, 1));
    'M': FScreen.DeleteLines(Parameter(0, 1));
    '@': FScreen.InsertCharacters(Parameter(0, 1));
    'P': FScreen.DeleteCharacters(Parameter(0, 1));
    'X': FScreen.EraseCharacters(Parameter(0, 1));
    'S': FScreen.ScrollUp(Parameter(0, 1));
    'T': FScreen.ScrollDown(Parameter(0, 1));
    'm':
      begin
        Pen := FScreen.Pen;
        SelectGraphicRendition(Pen, FParameters, FParameterCount);
        FScreen.Pen := Pen;
      end;
    'r': FScreen.SetScrollRegion(Parameter(0, 1) - 1, Parameter(1, FScreen.Rows) - 1);
    's': FScreen.SaveCursor;
    'u': FScreen.RestoreCursor;
    'n':
      case Parameter(0, 0) of
        5: Reply(#27'[0n');
        6: Reply(#27'[' + IntToStr(Row + 1) + ';' + IntToStr(Column + 1) + 'R');
      end;
    'c':
      if Parameter(0, 0) = 0 then
        Reply(#27'[?1;2c');
  end;
end;

procedure TTerminalEmulator.ProcessCommand(Value: Byte);
begin
  if FState = StateCommandEscape then
  begin
    { ESC \ ends the command; any other escape starts a sequence. }
    if Char(Value) = '\' then
    begin
      DispatchCommand;
      FState := StateGround;
    end
    else
    begin
      FState := StateEscape;
      ProcessEscape(Value);
    end;
    Exit;
  end;
  case Value of
    ControlBell:
      begin
        DispatchCommand;
        FState := StateGround;
      end;
    ControlEscape:
      FState := StateCommandEscape;
  else
    if Length(FCommand) < MaximumTitleLength then
      FCommand := FCommand + Char(Value);
  end;
end;

procedure TTerminalEmulator.DispatchCommand;
var
  Separator: LongInt;
  Kind: string;
begin
  Separator := Pos(';', FCommand);
  if Separator = 0 then
    Exit;
  Kind := Copy(FCommand, 1, Separator - 1);
  if ((Kind = '0') or (Kind = '2')) and Assigned(FOnTitle) then
    FOnTitle(Copy(FCommand, Separator + 1, Length(FCommand) - Separator));
end;

end.
