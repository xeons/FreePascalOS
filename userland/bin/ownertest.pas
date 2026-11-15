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
  ownertest - owned windows on the display server, for testing them

  ownertest

  Shows three windows filled with colours (libwindowing): A at 100,100
  (400x300, green), B owned by A at 150,150 (150x100, red) and C at
  300,250 (300x200, blue), overlapping A. Each key pressed (in whichever
  window has the keyboard) takes the next step, and every step prints a
  line:

    step 1   A hidden (B goes with it)
    step 2   A shown again (B too); A is in front
    step 3   C activated: in front of A
    step 4   A activated: in front of C
    step 5   C given A as its owner: in front of A
    step 6   A activated: C, which it owns, stays in front
    step 7   C owned by nothing again, A activated: A in front

  Whenever the server shows or hides a window it prints "visible NAME
  0|1", and at each step what each window's Visible property says
  ("visible A 1 B 1 C 1").
}
program OwnerTest;

{$mode objfpc}
{$H+}

uses
  Abi.SystemCalls,
  Sys.Format,
  Sys.Streams,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Windowing.Protocol,
  Windowing.Windows;

type
  TColorWindow = class(TWindow)
  private
    FColor: TColor;
  protected
    procedure Paint(var Canvas: TCanvas; const Area: TRectangle); override;
    procedure KeyDown(Code, Character, Modifiers: LongWord); override;
    procedure VisibilityChanged; override;
  public
    constructor CreateColored(const ATitle: string; Left, Top, Width, Height: LongInt; AColor: TColor;
      AOwner: TWindow);
  end;

var
  WindowA: TColorWindow;
  WindowB: TColorWindow;
  WindowC: TColorWindow;
  StepsTaken: LongInt;

procedure Say(Format: PChar; const Arguments: array of TFormatArgument);
begin
  WriteFormatted(StandardOutput, Format, Arguments);
  FlushStream(StandardOutput);
end;

procedure SayWhatIsVisible;
begin
  Say('visible A %d B %d C %d'#10, [ArgumentNumber(Ord(WindowA.Visible)), ArgumentNumber(Ord(WindowB.Visible)),
    ArgumentNumber(Ord(WindowC.Visible))]);
end;

procedure TakeNextStep;
begin
  Inc(StepsTaken);
  case StepsTaken of
    1: WindowA.Hide;
    2: WindowA.Show;
    3: WindowC.Activate;
    4: WindowA.Activate;
    5: WindowC.Owner := WindowA;
    6: WindowA.Activate;
    7:
      begin
        WindowC.Owner := nil;
        WindowA.Activate;
      end;
  else
    Exit;
  end;
  Say('step %d'#10, [ArgumentNumber(StepsTaken)]);
end;

constructor TColorWindow.CreateColored(const ATitle: string; Left, Top, Width, Height: LongInt; AColor: TColor;
  AOwner: TWindow);
begin
  FColor := AColor;
  inherited Create(ATitle, Left, Top, Width, Height, WindowFramed, AOwner);
end;

procedure TColorWindow.Paint(var Canvas: TCanvas; const Area: TRectangle);
begin
  FillRectangle(Canvas, Area, FColor);
end;

procedure TColorWindow.KeyDown(Code, Character, Modifiers: LongWord);
begin
  { What the step before did is known by now (its events came first). }
  SayWhatIsVisible;
  TakeNextStep;
end;

procedure TColorWindow.VisibilityChanged;
begin
  Say('visible %s %d'#10, [ArgumentText(PChar(Title)), ArgumentNumber(Ord(Visible))]);
end;

begin
  WindowA := TColorWindow.CreateColored('A', 100, 100, 400, 300, $FF40C040, nil);
  WindowA.Show;
  WindowB := TColorWindow.CreateColored('B', 150, 150, 150, 100, $FFC04040, WindowA);
  WindowB.Show;
  WindowC := TColorWindow.CreateColored('C', 300, 250, 300, 200, $FF4040C0, nil);
  WindowC.Show;
  Say('ready'#10, []);
  RunMessageLoop;
end.
