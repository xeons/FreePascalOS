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

  A TDialog is a framed window of a fixed size, centred on its owner (the
  window it asks for, which it stays above), or on the screen if it has
  none. ShowModal shows it and serves the program's windows until it
  ends (EndModal, or a button made with AddButton and a result, or its
  close button: ResultCancel), with the dialog modal meanwhile (the
  program's other windows disabled); it returns the result. Controls go on Root as in any control window; sizes are
  logical units, so the dialog's layout is the same on every display.
}
unit Controls.Dialogs;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
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
    { Width and Height of the client area, logical units; AOwner: the
      window it belongs to and is centred on (nil: the screen). }
    constructor CreateDialog(const ATitle: string; Width, Height: LongInt; AOwner: TWindow = nil);
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
  Windowing.Displays;

constructor TDialog.CreateDialog(const ATitle: string; Width, Height: LongInt; AOwner: TWindow);
var
  Left: LongInt;
  Top: LongInt;
begin
  { Connected first, for the display's size (creating the window fails
    if there is no display server). }
  ConnectToDisplay;
  if AOwner <> nil then
  begin
    Left := AOwner.ScreenLeft + (AOwner.ClientWidth - Width) div 2;
    Top := AOwner.ScreenTop + (AOwner.ClientHeight - Height) div 2;
  end
  else
  begin
    { The first display, whose scale the window starts at. }
    Left := (PixelsToLogical(ScreenWidth, DefaultScale) - Width) div 2;
    Top := (PixelsToLogical(ScreenHeight, DefaultScale) - Height) div 3;
  end;
  { All of it on the display it is on, the title bar first. }
  KeepOnDisplay(Left, Top, Width, Height);
  inherited Create(ATitle, Left, Top, Width, Height, WindowFramed, AOwner);
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
