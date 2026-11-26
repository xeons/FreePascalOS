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
  The editing a text field (a text-like input or a textarea) does for the
  keys that reach it, apart from the keyboard: the web view (and the host
  tests) turn keys into a TFieldAction. The value and its selection live
  in the DOM's form control state (Web.Dom.FormControls); each change of
  the value fires an InputEvent through OnEdited with its inputType. The
  element is held for the length of an action, since the page's
  listeners may remove it, replace it or move the focus while it runs.
}
unit WebView.FieldEditing;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom;

type
  TFieldAction = (
    FieldTypeText,        { the text replaces the selection }
    FieldLineBreak,       { Enter: a line break in a textarea, submission in a field }
    FieldDeleteBackward,  { Backspace }
    FieldDeleteForward,   { Delete }
    FieldMoveLeft,
    FieldMoveRight,
    FieldMoveUp,          { textareas only }
    FieldMoveDown,
    FieldLineStart,       { Home }
    FieldLineEnd,         { End }
    FieldValueStart,      { Ctrl+Home }
    FieldValueEnd,        { Ctrl+End }
    FieldSelectAll,
    FieldCopy,
    FieldCut,
    FieldPaste);

  TFieldActionOption = (
    FieldByWord,          { Ctrl: a word at a time }
    FieldExtend);         { Shift: the selection grows }
  TFieldActionOptions = set of TFieldActionOption;

  TFieldEditedEvent = procedure(Element: TElement; const InputType, Data: string) of object;
  TFieldElementEvent = procedure(Element: TElement) of object;
  TClipboardReadEvent = function: string of object;
  TClipboardWriteEvent = procedure(const Text: string) of object;

  TTextFieldEditor = class
  private
    FOnEdited: TFieldEditedEvent;
    FOnSelectionMoved: TFieldElementEvent;
    FOnSubmit: TFieldElementEvent;
    FOnReadClipboard: TClipboardReadEvent;
    FOnWriteClipboard: TClipboardWriteEvent;
  public
    { Does Action in Element (the focused element); False when it is not
      an editable text field or the action means nothing there (the key
      then does what it does elsewhere: Up in a single-line field
      scrolls). }
    function Perform(Element: TElement; Action: TFieldAction; const Text: string;
      Options: TFieldActionOptions): Boolean;
    { The value changed (an InputEvent with InputType and Data is due). }
    property OnEdited: TFieldEditedEvent read FOnEdited write FOnEdited;
    { Only the selection moved. }
    property OnSelectionMoved: TFieldElementEvent read FOnSelectionMoved write FOnSelectionMoved;
    { Enter in a single-line field: implicit submission. }
    property OnSubmit: TFieldElementEvent read FOnSubmit write FOnSubmit;
    property OnReadClipboard: TClipboardReadEvent read FOnReadClipboard write FOnReadClipboard;
    property OnWriteClipboard: TClipboardWriteEvent read FOnWriteClipboard write FOnWriteClipboard;
  end;

{ A connected text field that is not disabled. }
function IsEditableTextField(Element: TElement): Boolean;
{ The action a key press (a set 1 scan code with KeyCodeExtended for the
  E0 keys, the character it types, the system's modifier bits) is in a
  text field: characters, Backspace and Delete (Ctrl: a word), the arrows,
  Home and End (Shift extends the selection), Ctrl+A, Ctrl+C, Ctrl+X,
  Ctrl+V, Enter; False for the keys a field leaves alone (Tab, Escape,
  other Ctrl and Alt keys). Text is the typed character as UTF-8. }
function FieldActionOfKey(ScanCode, Character, Modifiers: LongWord; out Action: TFieldAction;
  out Options: TFieldActionOptions; out Text: string): Boolean;

implementation

uses
  SysUtils,
  Web.Dom.FormControls,
  WebView.ClipboardEvents,
  WebView.Elements,
  WebView.KeyNames,
  WebView.TextEditing;

const
  { The system's key codes (set 1 scan codes; $100 marks the E0 keys)
    and modifier bits. }
  ScanBackspace = $0E;
  ScanEnter = $1C;
  ScanNumpadEnter = $11C;
  ScanA = $1E;
  ScanC = $2E;
  ScanV = $2F;
  ScanX = $2D;
  ScanHome = $147;
  ScanArrowUp = $148;
  ScanArrowLeft = $14B;
  ScanArrowRight = $14D;
  ScanEnd = $14F;
  ScanArrowDown = $150;
  ScanDelete = $153;
  ModifierShiftBit = $01;
  ModifierControlBit = $02;
  ModifierAltBit = $04;

function FieldActionOfKey(ScanCode, Character, Modifiers: LongWord; out Action: TFieldAction;
  out Options: TFieldActionOptions; out Text: string): Boolean;
begin
  Result := True;
  Action := FieldTypeText;
  Text := '';
  Options := [];
  if (Modifiers and ModifierControlBit) <> 0 then
    Include(Options, FieldByWord);
  if (Modifiers and ModifierShiftBit) <> 0 then
    Include(Options, FieldExtend);
  if FieldByWord in Options then
  begin
    case ScanCode of
      ScanA: Action := FieldSelectAll;
      ScanC: Action := FieldCopy;
      ScanX: Action := FieldCut;
      ScanV: Action := FieldPaste;
      ScanBackspace: Action := FieldDeleteBackward;
      ScanDelete: Action := FieldDeleteForward;
      ScanArrowLeft: Action := FieldMoveLeft;
      ScanArrowRight: Action := FieldMoveRight;
      ScanHome: Action := FieldValueStart;
      ScanEnd: Action := FieldValueEnd;
    else
      Result := False;
    end;
    Exit;
  end;
  case ScanCode of
    ScanBackspace: Action := FieldDeleteBackward;
    ScanDelete: Action := FieldDeleteForward;
    ScanArrowLeft: Action := FieldMoveLeft;
    ScanArrowRight: Action := FieldMoveRight;
    ScanArrowUp: Action := FieldMoveUp;
    ScanArrowDown: Action := FieldMoveDown;
    ScanHome: Action := FieldLineStart;
    ScanEnd: Action := FieldLineEnd;
    ScanEnter, ScanNumpadEnter: Action := FieldLineBreak;
  else
    if (Character >= 32) and (Character <> 127) and ((Modifiers and ModifierAltBit) = 0) then
      Text := CodePointText(Character)
    else
      Result := False;
  end;
end;

function IsEditableTextField(Element: TElement): Boolean;
begin
  Result := (Element <> nil) and Element.IsConnected and IsTextControl(Element) and not IsDisabledControl(Element);
end;

function TTextFieldEditor.Perform(Element: TElement; Action: TFieldAction; const Text: string;
  Options: TFieldActionOptions): Boolean;
var
  Edit: TTextEdit;
  Start, Finish, MaximumLength: Integer;
  Direction, Before: string;
  ByWord, Extend, MultiLine, ReadOnly, Secret: Boolean;

  procedure Commit(const InputType, Data: string);
  begin
    if Edit.Value <> Before then
      SetTextControlValue(Element, Edit.Value);
    SetTextSelection(Element, Edit.SelectionStart, Edit.SelectionEnd, Edit.Direction);
    if Edit.Value <> Before then
    begin
      if Assigned(FOnEdited) then
        FOnEdited(Element, InputType, Data);
    end
    else if Assigned(FOnSelectionMoved) then
      FOnSelectionMoved(Element);
  end;

  procedure InsertText(const Inserted, InputType: string);
  begin
    if ReadOnly then
      Exit;
    if (MaximumLength >= 0) and (Utf16CountOf(Edit.Value) - (Edit.SelectionEnd - Edit.SelectionStart) +
      Utf16CountOf(Inserted) > MaximumLength) then
      Exit;
    Edit.Insert(Inserted, MultiLine);
    Commit(InputType, Inserted);
  end;

  procedure MoveCaret(How: TCaretMove);
  begin
    Edit.Move(How, Extend);
    Commit('', '');
  end;

  procedure PlaceCaret(Offset: Integer);
  begin
    Edit.SetSelection(Offset, Offset, 'none');
    Commit('', '');
  end;

  function ClipboardText: string;
  begin
    Result := '';
    if Assigned(FOnReadClipboard) then
      Result := FOnReadClipboard();
  end;

  procedure CopySelection;
  begin
    if Assigned(FOnWriteClipboard) then
      FOnWriteClipboard(Edit.SelectedText);
  end;

  { The clipboard event before a copy, cut or paste (WebView.ClipboardEvents):
    False when a listener cancelled it (a copy or cut then puts the data
    it set on the clipboard). The field is read again after it. }
  function ClipboardEventLetsGo: Boolean;
  var
    Outcome: TClipboardOutcome;
  begin
    if Action = FieldPaste then
      Outcome := FirePasteEvent(Element, ClipboardText)
    else if Action = FieldCut then
      Outcome := FireCopyEvent(Element, 'cut')
    else
      Outcome := FireCopyEvent(Element, 'copy');
    Result := Outcome.Proceed and IsEditableTextField(Element);
    if not Outcome.Proceed and Outcome.HasData and Assigned(FOnWriteClipboard) then
      FOnWriteClipboard(Outcome.Data);
  end;

begin
  Result := False;
  if not IsEditableTextField(Element) then
    Exit;
  Element.Retain;
  try
    if (Action in [FieldCopy, FieldCut, FieldPaste]) and not ClipboardEventLetsGo then
      Exit(True);
    MultiLine := Element.LocalName = 'textarea';
    Secret := (not MultiLine) and (InputType(Element) = 'password');
    ReadOnly := Element.HasAttribute('readonly');
    MaximumLength := -1;
    if Element.HasAttribute('maxlength') then
      MaximumLength := StrToIntDef(Element.GetAttribute('maxlength'), -1);
    ByWord := FieldByWord in Options;
    Extend := FieldExtend in Options;
    Edit.Value := TextControlValue(Element);
    Before := Edit.Value;
    GetTextSelection(Element, Start, Finish, Direction);
    Edit.SetSelection(Start, Finish, Direction);
    Result := True;
    case Action of
      FieldTypeText:
        InsertText(Text, 'insertText');
      FieldLineBreak:
        if MultiLine then
          InsertText(#10, 'insertLineBreak')
        else if Assigned(FOnSubmit) then
          FOnSubmit(Element);
      FieldDeleteBackward:
        if not ReadOnly and Edit.DeleteBackward(ByWord) then
        begin
          if ByWord then
            Commit('deleteWordBackward', '')
          else
            Commit('deleteContentBackward', '');
        end;
      FieldDeleteForward:
        if not ReadOnly and Edit.DeleteForward(ByWord) then
        begin
          if ByWord then
            Commit('deleteWordForward', '')
          else
            Commit('deleteContentForward', '');
        end;
      FieldMoveLeft:
        if ByWord then
          MoveCaret(MoveWordLeft)
        else
          MoveCaret(MoveCharacterLeft);
      FieldMoveRight:
        if ByWord then
          MoveCaret(MoveWordRight)
        else
          MoveCaret(MoveCharacterRight);
      FieldMoveUp:
        if MultiLine then
          MoveCaret(MoveLineUp)
        else
          Result := False;
      FieldMoveDown:
        if MultiLine then
          MoveCaret(MoveLineDown)
        else
          Result := False;
      FieldLineStart:
        MoveCaret(MoveLineStart);
      FieldLineEnd:
        MoveCaret(MoveLineEnd);
      FieldValueStart:
        PlaceCaret(0);
      FieldValueEnd:
        PlaceCaret(Utf16CountOf(Edit.Value));
      FieldSelectAll:
        begin
          Edit.Move(MoveAll, False);
          Commit('', '');
        end;
      FieldCopy:
        if Edit.HasSelectedText and not Secret then
          CopySelection;
      FieldCut:
        if Edit.HasSelectedText and not ReadOnly and not Secret then
        begin
          CopySelection;
          Edit.DeleteBackward(False);
          Commit('deleteByCut', '');
        end;
      FieldPaste:
        InsertText(ClipboardText, 'insertFromPaste');
    end;
  finally
    Element.Release;
  end;
end;

end.
