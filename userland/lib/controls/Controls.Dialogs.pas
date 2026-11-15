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
  Dialogs: windows that ask something and wait for the answer.

  A TDialog is a framed window of a fixed size, centred on the screen.
  ShowModal shows it and serves the program's windows until it ends
  (EndModal, or a button made with AddButton and a result, or its close
  button: ResultCancel), with the dialog modal meanwhile; it returns the
  result. Controls go on Root as in any control window; sizes are
  logical units, so the dialog's layout is the same on every display.
}
unit Controls.Dialogs;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Buttons;

const
  ResultNone = 0;
  ResultOk = 1;
  ResultCancel = 2;
  ResultYes = 3;
  ResultNo = 4;

type
  TDialog = class(TControlWindow)
  private
    FResult: LongInt;
    FDone: Boolean;
    procedure ButtonClicked(Sender: TControl);
  protected
    procedure CloseRequested; override;
  public
    { Width and Height of the client area, logical units. }
    constructor CreateDialog(const ATitle: string; Width, Height: LongInt);
    function ShowModal: LongInt;
    procedure EndModal(AResult: LongInt);
    { A button ending the dialog with AResult; Default and Cancel make it
      the one Enter or Escape presses. }
    function AddButton(const Caption: string; AResult: LongInt; Left, Top, Width, Height: LongInt;
      IsDefault: Boolean = False; IsCancel: Boolean = False): TButton;
    property ModalResult: LongInt read FResult;
  end;

implementation

uses
  Windowing.Protocol,
  Windowing.Connection,
  Windowing.Windows;

constructor TDialog.CreateDialog(const ATitle: string; Width, Height: LongInt);
var
  Left: LongInt;
  Top: LongInt;
begin
  { Connected first, for the screen's size (creating the window fails
    if there is no display server). }
  ConnectToDisplay;
  Left := (Unscaled(ScreenWidth) - Width) div 2;
  Top := (Unscaled(ScreenHeight) - Height) div 3;
  if Left < 0 then
    Left := 0;
  if Top < 0 then
    Top := 0;
  inherited Create(ATitle, Left, Top, Width, Height, WindowFramed);
end;

procedure TDialog.ButtonClicked(Sender: TControl);
begin
  EndModal(Sender.Tag);
end;

function TDialog.AddButton(const Caption: string; AResult: LongInt; Left, Top, Width, Height: LongInt;
  IsDefault, IsCancel: Boolean): TButton;
begin
  Result := TButton.Create(Root);
  Result.Text := Caption;
  Result.Tag := AResult;
  Result.SetBounds(Left, Top, Width, Height);
  Result.OnClick := @ButtonClicked;
  if IsDefault then
  begin
    Result.IsDefault := True;
    DefaultControl := Result;
  end;
  if IsCancel then
    CancelControl := Result;
end;

procedure TDialog.EndModal(AResult: LongInt);
begin
  FResult := AResult;
  FDone := True;
end;

procedure TDialog.CloseRequested;
begin
  EndModal(ResultCancel);
end;

function TDialog.ShowModal: LongInt;
begin
  FDone := False;
  FResult := ResultNone;
  Show;
  RunModal(Self, FDone);
  Hide;
  Result := FResult;
end;

end.
