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
  The controls tour's showcase of the theme's looks.

  On the Lists page: a group box with a golden header band holding a
  flat button, a split button and a drop-down button (both open a small
  menu) and a disabled button, and one with a navy band holding a
  progress bar part way along. On the Layout page: a marquee (moving
  stripes), where nothing compares the screen before and after.

  Prints "looks TEXT" when one of the buttons' menu items is chosen and
  "looks clicked TEXT" when a button is clicked.
}
unit Tour.Looks;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Buttons,
  Controls.Menus;

type
  TLooksShowcase = class
  private
    FMenu: TMenuItem;
    FSplitButton: TButton;
    procedure ItemChosen(Item: TMenuItem);
    procedure ButtonClicked(Sender: TControl);
  public
    { The group boxes on ListsPage (free from 184,40 to the right). }
    constructor Create(ListsPage: TControl);
    destructor Destroy; override;
    property SplitButton: TButton read FSplitButton;
  end;

{ A marquee progress bar along the top of Area. }
procedure AddMarquee(Area: TControl);

implementation

uses
  Controls.Panels,
  Controls.ProgressBar,
  Controls.LayoutRules,
  Tour.Output;

constructor TLooksShowcase.Create(ListsPage: TControl);
var
  Buttons: TGroupBox;
  Progress: TGroupBox;
  Button: TButton;
  Bar: TProgressBar;
begin
  inherited Create;
  FMenu := TMenuItem.Create('');
  FMenu.Add('First choice', nil, '');
  FMenu.Add('Second choice', nil, 'Ctrl+2');
  Buttons := TGroupBox.Create(ListsPage);
  Buttons.Text := 'Buttons';
  Buttons.HeaderStyle := GroupHeaderBand;
  Buttons.SetBounds(184, 40, 270, 88);
  Button := TButton.Create(Buttons);
  Button.Text := 'Flat';
  Button.Flat := True;
  Button.OnClick := @ButtonClicked;
  Button.SetBounds(10, 28, 75, 23);
  Button := TButton.Create(Buttons);
  Button.Text := 'Split';
  Button.Kind := ButtonSplit;
  Button.DropDownMenu := FMenu;
  Button.OnDropDownChoose := @ItemChosen;
  Button.OnClick := @ButtonClicked;
  Button.SetBounds(95, 28, 80, 23);
  FSplitButton := Button;
  Button := TButton.Create(Buttons);
  Button.Text := 'Menu';
  Button.Kind := ButtonDropDown;
  Button.DropDownMenu := FMenu;
  Button.OnDropDownChoose := @ItemChosen;
  Button.SetBounds(185, 28, 75, 23);
  Button := TButton.Create(Buttons);
  Button.Text := 'Disabled';
  Button.Enabled := False;
  Button.SetBounds(10, 57, 75, 23);
  Progress := TGroupBox.Create(ListsPage);
  Progress.Text := 'Progress';
  Progress.HeaderStyle := GroupHeaderSectionBand;
  Progress.SetBounds(184, 136, 270, 60);
  Bar := TProgressBar.Create(Progress);
  Bar.Position := 65;
  Bar.SetBounds(10, 30, 250, 18);
end;

destructor TLooksShowcase.Destroy;
begin
  FMenu.Free;
  inherited Destroy;
end;

procedure TLooksShowcase.ItemChosen(Item: TMenuItem);
begin
  Say('looks ' + Item.Text);
end;

procedure TLooksShowcase.ButtonClicked(Sender: TControl);
begin
  Say('looks clicked ' + Sender.Text);
end;

procedure AddMarquee(Area: TControl);
var
  Bar: TProgressBar;
begin
  Bar := TProgressBar.Create(Area);
  Bar.SetBounds(0, 0, 0, 14);
  Bar.Align := AlignTop;
  Bar.Margins := MakeSpacing(4, 4, 4, 2);
  Bar.Marquee := True;
end;

end.
