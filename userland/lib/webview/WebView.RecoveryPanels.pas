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
  What a web view shows when its content process fails it, drawn by
  the browser itself (the page's process is gone or stuck):

  - TCrashPanel covers the view: "This tab crashed", why, and Reload,
    which starts the page again in a new process.
  - THangBar runs across the top: the page is not responding (or keeps
    running scripts too long), Wait and Stop; Stop ends its process.
}
unit WebView.RecoveryPanels;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base,
  Controls.Panels,
  Controls.Labels,
  Controls.Buttons;

type
  TCrashPanel = class(TPanel)
  private
    FHeading: TLabel;
    FDetail: TLabel;
    FReload: TButton;
    FOnReload: TControlEvent;
    procedure ReloadClicked(Sender: TControl);
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    procedure SetReason(const Reason: string);
    property OnReload: TControlEvent read FOnReload write FOnReload;
  end;

  THangBar = class(TPanel)
  private
    FMessage: TLabel;
    FWait: TButton;
    FStop: TButton;
    FOnWait: TControlEvent;
    FOnStop: TControlEvent;
    procedure WaitClicked(Sender: TControl);
    procedure StopClicked(Sender: TControl);
  public
    constructor Create(AParent: TControl); override;
    procedure SetMessage(const Value: string);
    property OnWait: TControlEvent read FOnWait write FOnWait;
    property OnStop: TControlEvent read FOnStop write FOnStop;
  end;

implementation

uses
  Drawing.Rectangles,
  Windowing.Theme,
  Windowing.Connection;

const
  Padding = 12;
  LineHeight = 20;
  ButtonWidth = 90;
  ButtonHeight = 26;
  BarHeight = 40;

{ ---- TCrashPanel ---- }

constructor TCrashPanel.Create(AParent: TControl);
begin
  inherited Create(AParent);
  Align := AlignClient;
  Edge := PanelFlat;
  FHeading := TLabel.Create(Self);
  FHeading.ShowsMnemonic := False;
  FHeading.Text := 'This tab crashed';
  FHeading.SetBounds(40, 60, 500, LineHeight);
  FDetail := TLabel.Create(Self);
  FDetail.ShowsMnemonic := False;
  FDetail.Text := 'The page''s process ended. Other tabs are not affected.';
  FDetail.SetBounds(40, 60 + LineHeight + 4, 900, LineHeight);
  FReload := TButton.Create(Self);
  FReload.Text := '&Reload';
  FReload.SetBounds(40, 60 + 2 * LineHeight + 16, ButtonWidth, ButtonHeight);
  FReload.OnClick := @ReloadClicked;
end;

procedure TCrashPanel.Paint(var Canvas: TCanvas);
var
  Area: TRectangle;
begin
  inherited Paint(Canvas);
  { A band in the theme's header colour across the top. }
  Area := MakeRectangle(0, 0, RectangleWidth(PixelBounds), Scaled(32));
  FillHorizontalGradient(Canvas, Area, Theme.ActiveTitleStart, Theme.ActiveTitleEnd);
end;

procedure TCrashPanel.SetReason(const Reason: string);
begin
  FDetail.Text := Reason;
end;

procedure TCrashPanel.ReloadClicked(Sender: TControl);
begin
  if Assigned(FOnReload) then
    FOnReload(Self);
end;

{ ---- THangBar ---- }

constructor THangBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  Align := AlignTop;
  Edge := PanelRaised;
  SetBounds(0, 0, 400, BarHeight);
  FMessage := TLabel.Create(Self);
  FMessage.ShowsMnemonic := False;
  FMessage.Text := 'This page is not responding.';
  FMessage.SetBounds(Padding, (BarHeight - LineHeight) div 2, 360, LineHeight);
  FWait := TButton.Create(Self);
  FWait.Text := '&Wait';
  FWait.SetBounds(Padding * 2 + 360, (BarHeight - ButtonHeight) div 2, ButtonWidth, ButtonHeight);
  FWait.OnClick := @WaitClicked;
  FStop := TButton.Create(Self);
  FStop.Text := '&Stop page';
  FStop.SetBounds(Padding * 3 + 360 + ButtonWidth, (BarHeight - ButtonHeight) div 2, ButtonWidth, ButtonHeight);
  FStop.OnClick := @StopClicked;
end;

procedure THangBar.SetMessage(const Value: string);
begin
  FMessage.Text := Value;
end;

procedure THangBar.WaitClicked(Sender: TControl);
begin
  if Assigned(FOnWait) then
    FOnWait(Self);
end;

procedure THangBar.StopClicked(Sender: TControl);
begin
  if Assigned(FOnStop) then
    FOnStop(Self);
end;

end.
