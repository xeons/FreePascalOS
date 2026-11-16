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
  Multi-line edit boxes: text in lines, to type and change.

  Positions are a line and a character in it (UTF-8 by characters). The
  keys of the one line edit box work across lines: the arrows (up and
  down keep to the same X), Home and End within the row, Ctrl+Home and
  Ctrl+End to the ends of the text, Ctrl with Left and Right by words,
  Page Up and Down by a screenful, Shift with any of them to select;
  Enter splits the line (so the window's default button is not
  pressed), Backspace and Delete join lines at their ends. The edit
  commands (Controls.EditCommands: cut, copy, paste, select all) work
  from their keys and from the context menu of a right click; the
  clipboard holds lines joined with line feeds. Tab moves to the next
  control unless AcceptTabs.

  Every change goes through one place (ReplaceRange), which remembers it
  for Undo (Ctrl+Z) and Redo (Ctrl+Y), grouped as Controls.TextUndo
  says, and marks the text Modified. Find selects the next match (the
  view does that), Replace replaces the match selected and finds the
  next, ReplaceAll replaces every one as one change to undo. The view
  under it (Controls.TextView) shows the text: word wrap, the face, the
  scrolling, the caret.
}
unit Controls.TextEdit;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Windowing.Messages,
  Controls.Base,
  Controls.EditCommands,
  Controls.TextPositions,
  Controls.TextUndo,
  Controls.TextSearch,
  Controls.TextView;

type
  { (Declared again so programs need not name Controls.TextPositions.) }
  TTextPosition = Controls.TextPositions.TTextPosition;

  TTextEdit = class(TTextView)
  private
    FUndo: TTextUndoHistory;
    FSelecting: Boolean;
    FAcceptTabs: Boolean;
    FReadOnly: Boolean;
    FModified: Boolean;
    { ReplaceAll's changes are shown once, at the end. }
    FBatchDepth: LongInt;
    FBatchEdited: Boolean;
    procedure ReplaceRange(const Start, Finish: TTextPosition; const Inserted: string; Kind: TTextChangeKind);
    procedure TextEdited;
    procedure TypeText(const Typed: string);
    procedure DeleteBackward;
    procedure DeleteForward;
    function PositionBeforeCaret: TTextPosition;
    function PositionAfterCaret: TTextPosition;
    function WordStartBefore(const Position: TTextPosition): TTextPosition;
    function WordStartAfter(const Position: TTextPosition): TTextPosition;
    procedure MoveHorizontally(Forward, ByWord, Extend: Boolean);
  protected
    procedure UserMovedCaret; override;
    function ShowsAsField: Boolean; override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    { Replaces the whole text: nothing to undo, not modified. }
    procedure SetAllText(const Value: string); override;
    procedure CutToClipboard;
    procedure CopyToClipboard;
    procedure PasteFromClipboard;
    procedure RunEditCommand(Command: TEditCommand);
    { The selection replaced by NewText (inserted at the caret if there
      is none), as one change. }
    procedure ReplaceSelection(const NewText: string);
    procedure DeleteSelectedText;
    procedure Undo;
    procedure Redo;
    function CanUndo: Boolean;
    function CanRedo: Boolean;
    { Forgets what could be undone and redone. }
    procedure ClearUndo;
    { If the selection is Pattern, replaces it with Replacement; then
      finds the next match (True if there is one). }
    function ReplaceNext(const Pattern, Replacement: string; MatchCase: Boolean): Boolean;
    { Replaces every match of Pattern in the text; how many. }
    function ReplaceAll(const Pattern, Replacement: string; MatchCase: Boolean): LongInt;
    property AcceptTabs: Boolean read FAcceptTabs write FAcceptTabs;
    property ReadOnly: Boolean read FReadOnly write FReadOnly;
    { The text was changed by the user since SetAllText (or since the
      program said otherwise). }
    property Modified: Boolean read FModified write FModified;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Windowing.Protocol,
  Windowing.Windows,
  Controls.Keys,
  Controls.Clipboard;

const
  TabCharacter = 9;

{ Whether the character at Column of Text is part of a word (anything but
  spaces, tabs and punctuation). }
function IsWordCharacter(const Text: string; Column: LongInt): Boolean;
var
  Piece: string;
begin
  Piece := CharacterRange(Text, Column, 1);
  if Piece = '' then
    Exit(False);
  Result := (Length(Piece) > 1) or (Piece[1] in ['0'..'9', 'A'..'Z', 'a'..'z', '_']);
end;

constructor TTextEdit.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FUndo := TTextUndoHistory.Create;
end;

destructor TTextEdit.Destroy;
begin
  FUndo.Free;
  inherited Destroy;
end;

procedure TTextEdit.UserMovedCaret;
begin
  { Typing somewhere else is a new change to undo. }
  FUndo.BreakGroup;
end;

function TTextEdit.ShowsAsField: Boolean;
begin
  Result := Enabled and not FReadOnly;
end;

procedure TTextEdit.SetAllText(const Value: string);
begin
  inherited SetAllText(Value);
  FUndo.Clear;
  FModified := False;
end;

{ --- Changes ---------------------------------------------------------------------------- }

procedure TTextEdit.TextEdited;
begin
  if FBatchDepth > 0 then
  begin
    FBatchEdited := True;
    Exit;
  end;
  FDesiredX := -1;
  UpdateScrollBar;
  ScrollToCaret;
  Invalidate;
  ReportCaret;
  Changed;
end;

procedure TTextEdit.ReplaceRange(const Start, Finish: TTextPosition; const Inserted: string;
  Kind: TTextChangeKind);
var
  Removed: string;
begin
  if FReadOnly then
    Exit;
  Removed := TextBetween(Start, Finish);
  if (Removed = '') and (Inserted = '') then
    Exit;
  FUndo.AddChange(Start, Removed, Inserted, Kind);
  FCaret := ReplaceLines(Start, Finish, Inserted);
  FAnchor := FCaret;
  FModified := True;
  TextEdited;
end;

procedure TTextEdit.ReplaceSelection(const NewText: string);
begin
  ReplaceRange(SelectionStart, SelectionEnd, NewText, ChangeOther);
end;

procedure TTextEdit.DeleteSelectedText;
begin
  if HasSelection then
    ReplaceSelection('');
end;

procedure TTextEdit.TypeText(const Typed: string);
begin
  ReplaceRange(SelectionStart, SelectionEnd, Typed, ChangeTyping);
end;

function TTextEdit.PositionBeforeCaret: TTextPosition;
begin
  if FCaret.Column > 0 then
    Result := MakePosition(FCaret.Line, FCaret.Column - 1)
  else if FCaret.Line > 0 then
    Result := MakePosition(FCaret.Line - 1, LineLength(FCaret.Line - 1))
  else
    Result := FCaret;
end;

function TTextEdit.PositionAfterCaret: TTextPosition;
begin
  if FCaret.Column < LineLength(FCaret.Line) then
    Result := MakePosition(FCaret.Line, FCaret.Column + 1)
  else if FCaret.Line < FLines.Count - 1 then
    Result := MakePosition(FCaret.Line + 1, 0)
  else
    Result := FCaret;
end;

procedure TTextEdit.DeleteBackward;
begin
  if HasSelection then
    ReplaceSelection('')
  else
    ReplaceRange(PositionBeforeCaret, FCaret, '', ChangeDeletingBackward);
end;

procedure TTextEdit.DeleteForward;
begin
  if HasSelection then
    ReplaceSelection('')
  else
    ReplaceRange(FCaret, PositionAfterCaret, '', ChangeDeletingForward);
end;

procedure TTextEdit.Undo;
var
  Changes: TTextChanges;
  Index: LongInt;
  Change: TTextChange;
begin
  if FReadOnly then
    Exit;
  Changes := FUndo.TakeUndoGroup;
  if Length(Changes) = 0 then
    Exit;
  for Index := 0 to High(Changes) do
  begin
    Change := Changes[Index];
    FCaret := ReplaceLines(Change.Start, PositionAfterText(Change.Start, Change.Inserted), Change.Removed);
  end;
  FAnchor := FCaret;
  FModified := True;
  TextEdited;
end;

procedure TTextEdit.Redo;
var
  Changes: TTextChanges;
  Index: LongInt;
  Change: TTextChange;
begin
  if FReadOnly then
    Exit;
  Changes := FUndo.TakeRedoGroup;
  if Length(Changes) = 0 then
    Exit;
  for Index := 0 to High(Changes) do
  begin
    Change := Changes[Index];
    FCaret := ReplaceLines(Change.Start, PositionAfterText(Change.Start, Change.Removed), Change.Inserted);
  end;
  FAnchor := FCaret;
  FModified := True;
  TextEdited;
end;

function TTextEdit.CanUndo: Boolean;
begin
  Result := FUndo.CanUndo and not FReadOnly;
end;

function TTextEdit.CanRedo: Boolean;
begin
  Result := FUndo.CanRedo and not FReadOnly;
end;

procedure TTextEdit.ClearUndo;
begin
  FUndo.Clear;
end;

function TTextEdit.ReplaceNext(const Pattern, Replacement: string; MatchCase: Boolean): Boolean;
begin
  if HasSelection and (Pattern <> '') and TextMatches(SelectedText, Pattern, MatchCase) then
    ReplaceSelection(Replacement);
  Result := FindText(Pattern, MakeSearchOptions(MatchCase, SearchDown));
end;

function TTextEdit.ReplaceAll(const Pattern, Replacement: string; MatchCase: Boolean): LongInt;
var
  From: TTextPosition;
  MatchStart: TTextPosition;
  MatchEnd: TTextPosition;
  Options: TSearchOptions;
begin
  Result := 0;
  if FReadOnly then
    Exit;
  Options := MakeSearchOptions(MatchCase, SearchDown);
  From := MakePosition(0, 0);
  FUndo.BeginGroup;
  Inc(FBatchDepth);
  FBatchEdited := False;
  while FindInLines(FLines, Pattern, From, Options, MatchStart, MatchEnd) do
  begin
    ReplaceRange(MatchStart, MatchEnd, Replacement, ChangeOther);
    { Searching goes on after the replacement, so a replacement holding
      the pattern is not replaced again. }
    From := FCaret;
    Inc(Result);
  end;
  Dec(FBatchDepth);
  FUndo.EndGroup;
  if FBatchEdited then
    TextEdited;
end;

{ --- The clipboard --------------------------------------------------------------------- }

procedure TTextEdit.CopyToClipboard;
begin
  if HasSelection then
    SetClipboardText(SelectedText);
end;

procedure TTextEdit.CutToClipboard;
begin
  if not HasSelection or FReadOnly then
    Exit;
  SetClipboardText(SelectedText);
  ReplaceSelection('');
end;

procedure TTextEdit.PasteFromClipboard;
begin
  if FReadOnly or not ClipboardHasText then
    Exit;
  { Lines as this box keeps them: carriage returns are dropped. }
  ReplaceSelection(StringReplace(ClipboardText, #13, '', [rfReplaceAll]));
end;

procedure TTextEdit.RunEditCommand(Command: TEditCommand);
begin
  case Command of
    EditCommandCut: CutToClipboard;
    EditCommandCopy: CopyToClipboard;
    EditCommandPaste: PasteFromClipboard;
    EditCommandSelectAll: SelectAll;
  end;
end;

{ --- Keys -------------------------------------------------------------------------------- }

function TTextEdit.WordStartBefore(const Position: TTextPosition): TTextPosition;
var
  LineText: string;
  Column: LongInt;
begin
  if Position.Column = 0 then
  begin
    if Position.Line = 0 then
      Exit(Position);
    Exit(MakePosition(Position.Line - 1, LineLength(Position.Line - 1)));
  end;
  LineText := FLines[Position.Line];
  Column := Position.Column;
  while (Column > 0) and not IsWordCharacter(LineText, Column - 1) do
    Dec(Column);
  while (Column > 0) and IsWordCharacter(LineText, Column - 1) do
    Dec(Column);
  Result := MakePosition(Position.Line, Column);
end;

function TTextEdit.WordStartAfter(const Position: TTextPosition): TTextPosition;
var
  LineText: string;
  Column: LongInt;
  Count: LongInt;
begin
  Count := LineLength(Position.Line);
  if Position.Column >= Count then
  begin
    if Position.Line >= FLines.Count - 1 then
      Exit(Position);
    Exit(MakePosition(Position.Line + 1, 0));
  end;
  LineText := FLines[Position.Line];
  Column := Position.Column;
  while (Column < Count) and IsWordCharacter(LineText, Column) do
    Inc(Column);
  while (Column < Count) and not IsWordCharacter(LineText, Column) do
    Inc(Column);
  Result := MakePosition(Position.Line, Column);
end;

procedure TTextEdit.MoveHorizontally(Forward, ByWord, Extend: Boolean);
var
  Target: TTextPosition;
begin
  { An arrow without Shift leaves a selection at its end. }
  if HasSelection and not Extend and not ByWord then
  begin
    if Forward then
      Target := SelectionEnd
    else
      Target := SelectionStart;
  end
  else if ByWord and Forward then
    Target := WordStartAfter(FCaret)
  else if ByWord then
    Target := WordStartBefore(FCaret)
  else if Forward then
    Target := PositionAfterCaret
  else
    Target := PositionBeforeCaret;
  MoveCaret(Target.Line, Target.Column, Extend);
end;

function TTextEdit.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Extend: Boolean;
  Control: Boolean;
  Command: TEditCommand;
  Held: LongWord;
  LastLine: LongInt;
begin
  Result := True;
  Extend := (Modifiers and ModifierShift) <> 0;
  Control := (Modifiers and ModifierControl) <> 0;
  Held := Modifiers and (ModifierShift or ModifierControl or ModifierAlt);
  { Moving up and down keeps to one X; anything else starts again. }
  if (Code <> KeyArrowUp) and (Code <> KeyArrowDown) and (Code <> KeyPageUp) and (Code <> KeyPageDown) then
    FDesiredX := -1;
  if EditCommandOfKey(Code, Modifiers, Command) then
  begin
    RunEditCommand(Command);
    Exit;
  end;
  if (Code = KeyZ) and (Held = ModifierControl) then
  begin
    Undo;
    Exit;
  end;
  if ((Code = KeyY) and (Held = ModifierControl)) or ((Code = KeyZ) and (Held = ModifierControl or ModifierShift)) then
  begin
    Redo;
    Exit;
  end;
  LastLine := FLines.Count - 1;
  case Code of
    KeyArrowLeft: MoveHorizontally(False, Control, Extend);
    KeyArrowRight: MoveHorizontally(True, Control, Extend);
    KeyArrowUp: MoveCaretByRows(-1, Extend);
    KeyArrowDown: MoveCaretByRows(1, Extend);
    KeyPageUp: MoveCaretByRows(-VisibleRows, Extend);
    KeyPageDown: MoveCaretByRows(VisibleRows, Extend);
    KeyHome:
      if Control then
        MoveCaret(0, 0, Extend)
      else
        MoveCaretToRowStart(Extend);
    KeyEnd:
      if Control then
        MoveCaret(LastLine, LineLength(LastLine), Extend)
      else
        MoveCaretToRowEnd(Extend);
    KeyBackspace:
      DeleteBackward;
    KeyDelete:
      DeleteForward;
  else
    if IsEnterKey(Code) then
      ReplaceSelection(#10)
    else if (Character = TabCharacter) and FAcceptTabs then
      TypeText(#9)
    else if (Character >= 32) and (Character <> 127) and not Control then
      TypeText(Utf8Of(Character))
    else
      Result := False;
  end;
end;

{ --- The pointer --------------------------------------------------------------------------- }

procedure TTextEdit.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Position: TTextPosition;
begin
  if Button <> ButtonLeft then
    Exit;
  FSelecting := True;
  FDesiredX := -1;
  Position := PositionAt(X, Y);
  { Shift+click selects from where the caret was. }
  MoveCaret(Position.Line, Position.Column, (HeldModifiers and ModifierShift) <> 0);
end;

procedure TTextEdit.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Position: TTextPosition;
begin
  if not FSelecting then
    Exit;
  Position := PositionAt(X, Y);
  MoveCaret(Position.Line, Position.Column, True);
end;

procedure TTextEdit.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  FSelecting := False;
  { Opened as the button is let go, so the release does not land on the
    menu. }
  if Button = ButtonRight then
    ShowEditMenu(Self, X, Y, AvailableEditCommands(HasSelection, FReadOnly), @RunEditCommand);
end;

end.
