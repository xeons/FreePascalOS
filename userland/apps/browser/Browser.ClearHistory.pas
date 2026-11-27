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
  Tools > Clear Recent History...: the time range to clear (the last
  hour, two hours, four hours, today, everything) and what (browsing
  and download history, form and search history, cookies, cache,
  saved logins, offline website data), then Clear Now. The choice of
  what is kept as the setting ClearItems. "Settings for Clearing
  History" (Options > Privacy) chooses the same without a time range:
  what closing the browser clears.
}
unit Browser.ClearHistory;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

procedure ShowClearRecentHistory(Owner: TWindow);
{ Items: Browser.Settings' ClearItems letters. }
procedure ChooseClearItems(Owner: TWindow; var Items: string);

implementation

uses
  SysUtils,
  Controls.Base,
  Controls.Labels,
  Controls.Toggles,
  Controls.ComboBox,
  Controls.Panels,
  Controls.CommonDialogs,
  Browser.Settings,
  Browser.Application,
  Browser.Output;

const
  Width = 380;
  ItemLetters: array[0..5] of Char = ('h', 'f', 'c', 'a', 's', 'o');
  ItemNames: array[0..5] of string = ('&Browsing && Download History', '&Form && Search History', '&Cookies',
    'C&ache', 'Active &Logins', '&Offline Website Data');

type
  TClearDialog = class(TCommonDialog)
  public
    Checks: array[0..5] of TCheckBox;
    function Items: string;
  end;

function TClearDialog.Items: string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Checks) do
    if Checks[Index].Checked then
    begin
      Result := Result + ItemLetters[Index];
      { Downloads go with the browsing history. }
      if ItemLetters[Index] = 'h' then
        Result := Result + 'd';
    end;
end;

function MakeDialog(Owner: TWindow; const Title: string; const Items: string; Top: LongInt;
  out Height: LongInt): TClearDialog;
var
  Group: TGroupBox;
  Index: Integer;
begin
  Height := Top + 6 * 22 + 40 + 2 * DialogMargin + DialogButtonHeight;
  Result := TClearDialog.CreateDialog(Title, Width, Height, Owner);
  Group := TGroupBox.Create(Result.Root);
  Group.Text := 'Details';
  Group.SetBounds(DialogMargin, Top, Width - 2 * DialogMargin, 6 * 22 + 34);
  for Index := 0 to High(ItemNames) do
  begin
    Result.Checks[Index] := TCheckBox.Create(Group);
    Result.Checks[Index].Text := ItemNames[Index];
    Result.Checks[Index].SetBounds(12, 26 + Index * 22, Width - 50, 20);
    Result.Checks[Index].Checked := Pos(ItemLetters[Index], Items) > 0;
  end;
end;

procedure ShowClearRecentHistory(Owner: TWindow);
const
  RangeSeconds: array[0..4] of Int64 = (3600, 7200, 14400, -1, 0);
var
  Dialog: TClearDialog;
  Range: TComboBox;
  Caption: TLabel;
  Height: LongInt;
  Since, Now: Int64;
  Settings: TBrowserSettings;
begin
  Settings := BrowserApp.Settings;
  Dialog := MakeDialog(Owner, 'Clear Recent History', Settings.ClearItems, 44, Height);
  try
    Caption := TLabel.Create(Dialog.Root);
    Caption.Text := 'Time range to clear:';
    Caption.SetBounds(DialogMargin, DialogMargin + 3, 140, 18);
    Range := TComboBox.Create(Dialog.Root);
    Range.Items.Add('Last Hour');
    Range.Items.Add('Last Two Hours');
    Range.Items.Add('Last Four Hours');
    Range.Items.Add('Today');
    Range.Items.Add('Everything');
    Range.ItemIndex := 0;
    Range.SetBounds(150, DialogMargin, Width - 150 - DialogMargin, 22);
    Dialog.AddOkAndCancel(Width, Height);
    Dialog.OkButton.Text := 'Clear &Now';
    Say('clear-history open');
    if not Dialog.Execute then
      Exit;
    Now := BrowserApp.NowUnix;
    case RangeSeconds[Range.ItemIndex] of
      0: Since := 0;
      -1: Since := Now - (Now mod 86400);
    else
      Since := Now - RangeSeconds[Range.ItemIndex];
    end;
    Settings := BrowserApp.Settings;
    Settings.ClearItems := Dialog.Items;
    BrowserApp.Settings := Settings;
    BrowserApp.SaveSettings;
    BrowserApp.ClearPrivateData(Settings.ClearItems, Since);
  finally
    Dialog.Free;
  end;
end;

procedure ChooseClearItems(Owner: TWindow; var Items: string);
var
  Dialog: TClearDialog;
  Caption: TLabel;
  Height: LongInt;
begin
  Dialog := MakeDialog(Owner, 'Settings for Clearing History', Items, 36, Height);
  try
    Caption := TLabel.Create(Dialog.Root);
    Caption.Text := 'When I close Browser, it should clear:';
    Caption.SetBounds(DialogMargin, DialogMargin, Width - 2 * DialogMargin, 18);
    Dialog.AddOkAndCancel(Width, Height);
    if Dialog.Execute then
      Items := Dialog.Items;
  finally
    Dialog.Free;
  end;
end;

end.
