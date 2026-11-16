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
  Notepad's window with its menus: File, Edit, Format, View and Help,
  their accelerators, and the status bar with the caret's line and
  column.

  The Edit menu's items are enabled as things are when it opens (Undo
  when there is something to undo, Cut, Copy and Delete with a
  selection, Paste with text on the clipboard); an accelerator checks
  the same first. Find and Replace remember what was looked for, so
  Find Next (F3) looks again. Word wrap, the status bar and the face
  chosen with Format > Font are kept in the user's settings
  (Notepad.Settings) as soon as they are chosen, and the next Notepad
  starts with them. When they change while it runs (another Notepad,
  the settings tool), it takes them at once (Windowing.SettingsChanges).
}
unit Notepad.MainWindow;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Fonts,
  Configuration.Changes,
  Controls.Base,
  Controls.StatusBar,
  Controls.Menus,
  Controls.TextEdit,
  Controls.FindDialog,
  Controls.TextSearch,
  Notepad.DocumentWindow;

type
  TNotepadWindow = class(TDocumentWindow)
  private
    FMenuBar: TMenuBar;
    FStatusBar: TStatusBar;
    FUndoItem: TMenuItem;
    FRedoItem: TMenuItem;
    FCutItem: TMenuItem;
    FCopyItem: TMenuItem;
    FPasteItem: TMenuItem;
    FDeleteItem: TMenuItem;
    FFindNextItem: TMenuItem;
    FWordWrapItem: TMenuItem;
    FStatusBarItem: TMenuItem;
    FFindText: string;
    FReplaceText: string;
    FMatchCase: Boolean;
    FDirection: TSearchDirection;
    procedure BuildMenus;
    procedure BuildFileMenu;
    procedure BuildEditMenu;
    procedure BuildFormatAndViewMenus;
    function AddItem(Menu: TMenuItem; const Text: string; Handler: TMenuItemEvent; const Shortcut: string;
      Code, Modifiers: LongWord): TMenuItem;
    procedure EditMenuOpening(Item: TMenuItem);
    procedure CaretMoved(Sender: TControl);
    procedure ShowCaretPlace;
    procedure PlaceStatusPanels;
    procedure NewChosen(Item: TMenuItem);
    procedure OpenChosen(Item: TMenuItem);
    procedure SaveChosen(Item: TMenuItem);
    procedure SaveAsChosen(Item: TMenuItem);
    procedure ExitChosen(Item: TMenuItem);
    procedure UndoChosen(Item: TMenuItem);
    procedure RedoChosen(Item: TMenuItem);
    procedure CutChosen(Item: TMenuItem);
    procedure CopyChosen(Item: TMenuItem);
    procedure PasteChosen(Item: TMenuItem);
    procedure DeleteChosen(Item: TMenuItem);
    procedure FindChosen(Item: TMenuItem);
    procedure FindNextChosen(Item: TMenuItem);
    procedure ReplaceChosen(Item: TMenuItem);
    procedure GoToChosen(Item: TMenuItem);
    procedure SelectAllChosen(Item: TMenuItem);
    procedure TimeDateChosen(Item: TMenuItem);
    procedure WordWrapChosen(Item: TMenuItem);
    procedure FontChosen(Item: TMenuItem);
    procedure StatusBarChosen(Item: TMenuItem);
    procedure ApplyRememberedFormat;
    procedure NotepadSettingsChanged(const Group: string; const Changes: TSettingChanges);
    procedure AboutChosen(Item: TMenuItem);
    procedure ShowFindDialog(Replacing: Boolean);
    procedure RememberSearch(Dialog: TFindDialog);
    procedure FindAgain(Dialog: TFindDialog);
    procedure DialogFindNext(Dialog: TFindDialog);
    procedure DialogReplace(Dialog: TFindDialog);
    procedure DialogReplaceAll(Dialog: TFindDialog);
  protected
    procedure Resized; override;
  public
    constructor Create;
    destructor Destroy; override;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Time,
  Sys.LocalTime,
  Windowing.Windows,
  Windowing.SettingsChanges,
  Controls.Keys,
  Controls.Clipboard,
  Controls.MessageBoxes,
  Controls.FontDialog,
  Notepad.GoToDialog,
  Notepad.Settings,
  Notepad.Output;

const
  { Logical units: the status bar's panel with the caret's place. }
  CaretPanelWidth = 150;
  NoKey = 0;

constructor TNotepadWindow.Create;
begin
  inherited Create;
  BuildMenus;
  FStatusBar := TStatusBar.Create(Root);
  PlaceStatusPanels;
  FEditor.OnCaretMoved := @CaretMoved;
  ApplyRememberedFormat;
  SubscribeToSettings(NotepadSettingsGroup, @NotepadSettingsChanged);
  FDirection := SearchDown;
  ShowCaretPlace;
  UpdateTitle;
end;

destructor TNotepadWindow.Destroy;
begin
  UnsubscribeFromSettings(@NotepadSettingsChanged);
  inherited Destroy;
end;

function TNotepadWindow.AddItem(Menu: TMenuItem; const Text: string; Handler: TMenuItemEvent;
  const Shortcut: string; Code, Modifiers: LongWord): TMenuItem;
begin
  Result := Menu.Add(Text, Handler, Shortcut);
  if Code <> NoKey then
    AddItemAccelerator(Self, Result, Code, Modifiers);
end;

procedure TNotepadWindow.BuildMenus;
begin
  FMenuBar := TMenuBar.Create(Root);
  BuildFileMenu;
  BuildEditMenu;
  BuildFormatAndViewMenus;
end;

procedure TNotepadWindow.BuildFileMenu;
var
  Menu: TMenuItem;
begin
  Menu := FMenuBar.Menu.Add('&File');
  AddItem(Menu, '&New', @NewChosen, 'Ctrl+N', KeyN, ModifierControl);
  AddItem(Menu, '&Open...', @OpenChosen, 'Ctrl+O', KeyO, ModifierControl);
  AddItem(Menu, '&Save', @SaveChosen, 'Ctrl+S', KeyS, ModifierControl);
  AddItem(Menu, 'Save &As...', @SaveAsChosen, '', NoKey, 0);
  Menu.AddSeparator;
  AddItem(Menu, 'E&xit', @ExitChosen, '', NoKey, 0);
end;

procedure TNotepadWindow.BuildEditMenu;
var
  Menu: TMenuItem;
begin
  Menu := FMenuBar.Menu.Add('&Edit');
  Menu.OnOpening := @EditMenuOpening;
  FUndoItem := AddItem(Menu, '&Undo', @UndoChosen, 'Ctrl+Z', KeyZ, ModifierControl);
  FRedoItem := AddItem(Menu, '&Redo', @RedoChosen, 'Ctrl+Y', KeyY, ModifierControl);
  Menu.AddSeparator;
  { Cut, Copy, Paste and Select All have their keys in the edit box
    itself; Delete is the Delete key. }
  FCutItem := AddItem(Menu, 'Cu&t', @CutChosen, 'Ctrl+X', NoKey, 0);
  FCopyItem := AddItem(Menu, '&Copy', @CopyChosen, 'Ctrl+C', NoKey, 0);
  FPasteItem := AddItem(Menu, '&Paste', @PasteChosen, 'Ctrl+V', NoKey, 0);
  FDeleteItem := AddItem(Menu, 'De&lete', @DeleteChosen, 'Del', NoKey, 0);
  Menu.AddSeparator;
  AddItem(Menu, '&Find...', @FindChosen, 'Ctrl+F', KeyF, ModifierControl);
  FFindNextItem := AddItem(Menu, 'Find &Next', @FindNextChosen, 'F3', KeyF3, 0);
  AddItem(Menu, 'R&eplace...', @ReplaceChosen, 'Ctrl+H', KeyH, ModifierControl);
  AddItem(Menu, '&Go To...', @GoToChosen, 'Ctrl+G', KeyG, ModifierControl);
  Menu.AddSeparator;
  AddItem(Menu, 'Select &All', @SelectAllChosen, 'Ctrl+A', NoKey, 0);
  AddItem(Menu, 'Time/&Date', @TimeDateChosen, 'F5', KeyF5, 0);
end;

procedure TNotepadWindow.BuildFormatAndViewMenus;
var
  Menu: TMenuItem;
begin
  Menu := FMenuBar.Menu.Add('F&ormat');
  FWordWrapItem := AddItem(Menu, '&Word Wrap', @WordWrapChosen, '', NoKey, 0);
  AddItem(Menu, '&Font...', @FontChosen, '', NoKey, 0);
  Menu := FMenuBar.Menu.Add('&View');
  FStatusBarItem := AddItem(Menu, '&Status Bar', @StatusBarChosen, '', NoKey, 0);
  FStatusBarItem.Checked := True;
  Menu := FMenuBar.Menu.Add('&Help');
  AddItem(Menu, '&About Notepad', @AboutChosen, '', NoKey, 0);
end;

{ The caret's place in a panel at the right, the rest empty (the texts
  stay as the widths change). }
procedure TNotepadWindow.PlaceStatusPanels;
begin
  FStatusBar.SetPanels([ClientWidth - CaretPanelWidth, CaretPanelWidth]);
end;

procedure TNotepadWindow.Resized;
begin
  inherited Resized;
  if FStatusBar <> nil then
    PlaceStatusPanels;
end;

procedure TNotepadWindow.EditMenuOpening(Item: TMenuItem);
begin
  FUndoItem.Enabled := FEditor.CanUndo;
  FRedoItem.Enabled := FEditor.CanRedo;
  FCutItem.Enabled := FEditor.HasSelection;
  FCopyItem.Enabled := FEditor.HasSelection;
  FDeleteItem.Enabled := FEditor.HasSelection;
  FPasteItem.Enabled := ClipboardHasText;
end;

{ --- The status bar ------------------------------------------------------------------------ }

procedure TNotepadWindow.ShowCaretPlace;
var
  Line: LongInt;
  Column: LongInt;
begin
  Line := FEditor.CaretLine + 1;
  Column := FEditor.CaretColumn + 1;
  FStatusBar.PanelText[1] := '   Ln ' + IntToStr(Line) + ', Col ' + IntToStr(Column);
  Say('status ' + IntToStr(Line) + ' ' + IntToStr(Column));
end;

procedure TNotepadWindow.CaretMoved(Sender: TControl);
begin
  ShowCaretPlace;
end;

{ --- File ----------------------------------------------------------------------------------- }

procedure TNotepadWindow.NewChosen(Item: TMenuItem);
begin
  NewDocument;
end;

procedure TNotepadWindow.OpenChosen(Item: TMenuItem);
begin
  ChooseAndOpenDocument;
end;

procedure TNotepadWindow.SaveChosen(Item: TMenuItem);
begin
  SaveDocument;
end;

procedure TNotepadWindow.SaveAsChosen(Item: TMenuItem);
begin
  SaveDocumentAs;
end;

procedure TNotepadWindow.ExitChosen(Item: TMenuItem);
begin
  ExitIfAllowed;
end;

{ --- Edit ----------------------------------------------------------------------------------- }

procedure TNotepadWindow.UndoChosen(Item: TMenuItem);
begin
  FEditor.Undo;
  Say('undone ' + FEditor.Lines[FEditor.CaretLine]);
end;

procedure TNotepadWindow.RedoChosen(Item: TMenuItem);
begin
  FEditor.Redo;
  Say('redone ' + FEditor.Lines[FEditor.CaretLine]);
end;

procedure TNotepadWindow.CutChosen(Item: TMenuItem);
begin
  FEditor.CutToClipboard;
end;

procedure TNotepadWindow.CopyChosen(Item: TMenuItem);
begin
  FEditor.CopyToClipboard;
end;

procedure TNotepadWindow.PasteChosen(Item: TMenuItem);
begin
  FEditor.PasteFromClipboard;
end;

procedure TNotepadWindow.DeleteChosen(Item: TMenuItem);
begin
  FEditor.DeleteSelectedText;
end;

procedure TNotepadWindow.SelectAllChosen(Item: TMenuItem);
begin
  FEditor.SelectAll;
end;

procedure TNotepadWindow.TimeDateChosen(Item: TMenuItem);
var
  Local: TLocalTime;
begin
  { Local time, in the system's time zone. }
  DecodeLocalTime(CurrentTime, Local);
  FEditor.ReplaceSelection(Format('%.2d:%.2d %.4d-%.2d-%.2d', [Local.DateTime.Hour, Local.DateTime.Minute,
    Local.DateTime.Year, Local.DateTime.Month, Local.DateTime.Day]));
end;

procedure TNotepadWindow.GoToChosen(Item: TMenuItem);
var
  Line: LongInt;
begin
  if AskForLine(Self, FEditor.CaretLine + 1, FEditor.Lines.Count, Line) then
    FEditor.GoToLine(Line - 1);
end;

{ --- Find and replace --------------------------------------------------------------------- }

procedure TNotepadWindow.RememberSearch(Dialog: TFindDialog);
begin
  FFindText := Dialog.FindText;
  FMatchCase := Dialog.MatchCase;
  if Dialog.Replacing then
    FReplaceText := Dialog.ReplaceText
  else
    FDirection := Dialog.Direction;
end;

{ Looks for the text remembered; says so in a message box (owned by the
  dialog, when there is one) if there is no more. }
procedure TNotepadWindow.FindAgain(Dialog: TFindDialog);
var
  MessageOwner: TWindow;
  Match: TTextPosition;
begin
  if FEditor.FindText(FFindText, MakeSearchOptions(FMatchCase, FDirection)) then
  begin
    Match := FEditor.SelectionStart;
    Say('found ' + IntToStr(Match.Line + 1) + ' ' + IntToStr(Match.Column + 1));
    Exit;
  end;
  Say('not-found ' + FFindText);
  MessageOwner := Dialog;
  if MessageOwner = nil then
    MessageOwner := Self;
  ShowMessageBox('Notepad', 'Cannot find "' + FFindText + '"', MessageOk, SignInformation, MessageOwner);
end;

procedure TNotepadWindow.DialogFindNext(Dialog: TFindDialog);
begin
  RememberSearch(Dialog);
  if Dialog.Replacing then
    FDirection := SearchDown;
  FindAgain(Dialog);
end;

procedure TNotepadWindow.DialogReplace(Dialog: TFindDialog);
begin
  RememberSearch(Dialog);
  if not FEditor.ReplaceNext(FFindText, FReplaceText, FMatchCase) then
  begin
    Say('not-found ' + FFindText);
    ShowMessageBox('Notepad', 'Cannot find "' + FFindText + '"', MessageOk, SignInformation, Dialog);
  end;
end;

procedure TNotepadWindow.DialogReplaceAll(Dialog: TFindDialog);
begin
  RememberSearch(Dialog);
  Say('replaced ' + IntToStr(FEditor.ReplaceAll(FFindText, FReplaceText, FMatchCase)));
end;

procedure TNotepadWindow.ShowFindDialog(Replacing: Boolean);
var
  Dialog: TFindDialog;
begin
  if Replacing then
    Dialog := TFindDialog.CreateFindDialog('Replace', True, Self)
  else
    Dialog := TFindDialog.CreateFindDialog('Find', False, Self);
  try
    { What is selected (on one line) is what to look for, else what was
      looked for last. }
    if FEditor.HasSelection and (FEditor.SelectionStart.Line = FEditor.SelectionEnd.Line) then
      Dialog.FindText := FEditor.SelectedText
    else
      Dialog.FindText := FFindText;
    Dialog.ReplaceText := FReplaceText;
    Dialog.MatchCase := FMatchCase;
    Dialog.Direction := FDirection;
    Dialog.OnFindNext := @DialogFindNext;
    Dialog.OnReplace := @DialogReplace;
    Dialog.OnReplaceAll := @DialogReplaceAll;
    Dialog.Execute;
    RememberSearch(Dialog);
  finally
    Dialog.Free;
  end;
end;

procedure TNotepadWindow.FindChosen(Item: TMenuItem);
begin
  ShowFindDialog(False);
end;

procedure TNotepadWindow.FindNextChosen(Item: TMenuItem);
begin
  if FFindText = '' then
    ShowFindDialog(False)
  else
    FindAgain(nil);
end;

procedure TNotepadWindow.ReplaceChosen(Item: TMenuItem);
begin
  ShowFindDialog(True);
end;

{ --- Format, View, Help ----------------------------------------------------------------------- }

const
  OnOff: array[Boolean] of string = ('off', 'on');
  Weights: array[Boolean] of string = ('regular', 'bold');

{ Word wrap, the status bar and the face as the user last chose them. }
procedure TNotepadWindow.ApplyRememberedFormat;
var
  Format: TNotepadFormat;
  Family: TFontFamily;
begin
  Format := RememberedFormat(FEditor);
  FEditor.WordWrap := Format.WordWrap;
  FWordWrapItem.Checked := Format.WordWrap;
  FStatusBar.Visible := Format.StatusBar;
  FStatusBarItem.Checked := Format.StatusBar;
  Family := Format.FontFamily;
  if (Family <> FEditor.FontFamily) or (Format.FontPointTenths <> FEditor.FontPointTenths) or
     (Format.FontBold <> FEditor.FontBold) then
    FEditor.SetFont(Family, Format.FontPointTenths, Format.FontBold);
  Say('settings word-wrap ' + OnOff[Format.WordWrap] + ', status-bar ' + OnOff[Format.StatusBar] + ', font ' +
    IntToStr(Format.FontPointTenths) + ' ' + Weights[Format.FontBold] + ' ' + FamilyName(Family));
end;

{ Changed elsewhere: taken if it differs from what the window shows (its
  own changes are heard too, and need nothing). }
procedure TNotepadWindow.NotepadSettingsChanged(const Group: string; const Changes: TSettingChanges);
var
  Format: TNotepadFormat;
begin
  Format := RememberedFormat(FEditor);
  if (Format.WordWrap = FEditor.WordWrap) and (Format.StatusBar = FStatusBar.Visible) and
     (Format.FontFamily = FEditor.FontFamily) and
     (Format.FontPointTenths = FEditor.FontPointTenths) and (Format.FontBold = FEditor.FontBold) then
    Exit;
  ApplyRememberedFormat;
end;

procedure TNotepadWindow.WordWrapChosen(Item: TMenuItem);
begin
  FEditor.WordWrap := not FEditor.WordWrap;
  FWordWrapItem.Checked := FEditor.WordWrap;
  RememberWordWrap(FEditor.WordWrap);
  Say('wrap ' + OnOff[FEditor.WordWrap] + ' ' + IntToStr(FEditor.RowCount));
end;

procedure TNotepadWindow.FontChosen(Item: TMenuItem);
var
  Family: TFontFamily;
  PointTenths: LongWord;
  Bold: Boolean;
begin
  Family := FEditor.FontFamily;
  PointTenths := FEditor.FontPointTenths;
  Bold := FEditor.FontBold;
  if not ChooseFontOfFamily(Family, PointTenths, Bold) then
    Exit;
  FEditor.SetFont(Family, PointTenths, Bold);
  RememberFont(Family, PointTenths, Bold);
  Say('font ' + IntToStr(PointTenths) + ' ' + Weights[Bold] + ' ' + FamilyName(Family));
end;

procedure TNotepadWindow.StatusBarChosen(Item: TMenuItem);
begin
  FStatusBar.Visible := not FStatusBar.Visible;
  FStatusBarItem.Checked := FStatusBar.Visible;
  RememberStatusBar(FStatusBar.Visible);
end;

procedure TNotepadWindow.AboutChosen(Item: TMenuItem);
begin
  ShowMessageBox('About Notepad', 'Notepad'#10'A plain text editor for FreePascalOS.', MessageOk, SignInformation,
    Self);
end;

end.
