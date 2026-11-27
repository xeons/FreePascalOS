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
  Manage Search Engine List: the engines in the order the search bar
  offers them, with their keywords; Move Up, Move Down, Edit Keyword...,
  Remove, Add... (a name and a search URL with "%s" for the words) and
  Restore Defaults. Changes are kept when the dialog closes with OK.
}
unit Browser.SearchEngineDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

procedure ManageSearchEngines(Owner: TWindow);

implementation

uses
  SysUtils,
  Classes,
  Controls.Base,
  Controls.Labels,
  Controls.Buttons,
  Controls.ListView,
  Controls.CommonDialogs,
  Controls.MessageBoxes,
  Browser.SearchEngines,
  Browser.InputDialog,
  Browser.Application,
  Browser.Output;

const
  Width = 500;
  Height = 340;

type
  TEnginesDialog = class(TCommonDialog)
  public
    Engines: TSearchEngineList;
    List: TListView;
    procedure Fill(Chosen: Integer);
    procedure UpClicked(Sender: TControl);
    procedure DownClicked(Sender: TControl);
    procedure KeywordClicked(Sender: TControl);
    procedure RemoveClicked(Sender: TControl);
    procedure AddClicked(Sender: TControl);
    procedure RestoreClicked(Sender: TControl);
  end;

procedure TEnginesDialog.Fill(Chosen: Integer);
var
  Index: Integer;
begin
  List.Clear;
  for Index := 0 to Engines.Count - 1 do
    List.AddRow([Engines[Index].Name, Engines[Index].Keyword, SearchHost(Engines[Index].Url)]);
  if (Chosen >= 0) and (Chosen < Engines.Count) then
    List.ItemIndex := Chosen;
end;

procedure TEnginesDialog.UpClicked(Sender: TControl);
var
  Index: Integer;
begin
  Index := List.ItemIndex;
  if Index > 0 then
  begin
    Engines.Move(Index, Index - 1);
    Fill(Index - 1);
  end;
end;

procedure TEnginesDialog.DownClicked(Sender: TControl);
var
  Index: Integer;
begin
  Index := List.ItemIndex;
  if (Index >= 0) and (Index < Engines.Count - 1) then
  begin
    Engines.Move(Index, Index + 1);
    Fill(Index + 1);
  end;
end;

procedure TEnginesDialog.KeywordClicked(Sender: TControl);
var
  Index, Other: Integer;
  Keyword: string;
begin
  Index := List.ItemIndex;
  if Index < 0 then
    Exit;
  Keyword := Engines[Index].Keyword;
  if not AskText(Self, 'Edit Keyword', 'Keyword for ' + Engines[Index].Name + ' (typed before words in the location ' +
    'bar):', Keyword) then
    Exit;
  Other := Engines.IndexOfKeyword(Trim(Keyword));
  if (Trim(Keyword) <> '') and (Other >= 0) and (Other <> Index) then
  begin
    ShowMessageBox('Edit Keyword', 'The keyword is already used by ' + Engines[Other].Name + '.', MessageOk,
      SignWarning, Self);
    Exit;
  end;
  Engines.SetKeyword(Index, Keyword);
  Fill(Index);
end;

procedure TEnginesDialog.RemoveClicked(Sender: TControl);
var
  Index: Integer;
begin
  Index := List.ItemIndex;
  if Index < 0 then
    Exit;
  Engines.Remove(Index);
  Fill(Index - 1);
end;

procedure TEnginesDialog.AddClicked(Sender: TControl);
var
  Name, Url: string;
  Index: Integer;
begin
  Name := '';
  if not AskText(Self, 'Add Search Engine', 'Name:', Name) or (Trim(Name) = '') then
    Exit;
  Url := 'https://';
  if not AskText(Self, 'Add Search Engine', 'Search URL ("%s" stands for the words):', Url) then
    Exit;
  Index := Engines.Add(Name, Url, '');
  if Index < 0 then
  begin
    ShowMessageBox('Add Search Engine', 'The name is taken, or the URL is not an http or https address with %s in it.',
      MessageOk, SignWarning, Self);
    Exit;
  end;
  Fill(Index);
end;

procedure TEnginesDialog.RestoreClicked(Sender: TControl);
begin
  Engines.RestoreDefaults;
  Fill(-1);
end;

function AddSideButton(Dialog: TEnginesDialog; const Text: string; Top: LongInt; Handler: TControlEvent): TButton;
begin
  Result := TButton.Create(Dialog.Root);
  Result.Text := Text;
  Result.SetBounds(Width - 8 - 130, Top, 130, 23);
  Result.Anchors := [akTop, akRight];
  Result.OnClick := Handler;
end;

procedure ManageSearchEngines(Owner: TWindow);
var
  Dialog: TEnginesDialog;
  Caption: TLabel;
  Lines: TStringList;
begin
  Dialog := TEnginesDialog.CreateDialog('Manage Search Engine List', Width, Height, Owner);
  Lines := TStringList.Create;
  try
    { A copy: Cancel leaves the browser's list as it was. }
    Dialog.Engines := TSearchEngineList.Create;
    BrowserApp.Engines.SaveToLines(Lines);
    Dialog.Engines.LoadFromLines(Lines);
    Caption := TLabel.Create(Dialog.Root);
    Caption.Text := 'Search engines, in the order the search bar offers them (none is used until you choose one):';
    Caption.ShowsMnemonic := False;
    Caption.SetBounds(8, 8, Width - 16, 18);
    Dialog.List := TListView.Create(Dialog.Root);
    Dialog.List.SetBounds(8, 30, Width - 8 - 130 - 16, Height - 30 - 50);
    Dialog.List.Anchors := [akLeft, akTop, akRight, akBottom];
    Dialog.List.AddColumn('Name', 150);
    Dialog.List.AddColumn('Keyword', 70);
    Dialog.List.AddColumn('Sends to', 120);
    AddSideButton(Dialog, 'Move &Up', 30, @Dialog.UpClicked);
    AddSideButton(Dialog, 'Move &Down', 58, @Dialog.DownClicked);
    AddSideButton(Dialog, 'Edit &Keyword...', 86, @Dialog.KeywordClicked);
    AddSideButton(Dialog, '&Remove', 114, @Dialog.RemoveClicked);
    AddSideButton(Dialog, '&Add...', 150, @Dialog.AddClicked);
    AddSideButton(Dialog, 'Restore D&efaults', 186, @Dialog.RestoreClicked);
    Dialog.AddOkAndCancel(Width, Height);
    Dialog.Fill(0);
    Say('search-engines open');
    if Dialog.Execute then
    begin
      Lines.Clear;
      Dialog.Engines.SaveToLines(Lines);
      BrowserApp.Engines.LoadFromLines(Lines);
      BrowserApp.SaveSearchEngines;
    end;
  finally
    Dialog.Engines.Free;
    Lines.Free;
    Dialog.Free;
  end;
end;

end.
