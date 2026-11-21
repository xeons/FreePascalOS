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
  webbrowse: the browser engine on the Linux host, for debugging real
  sites. It loads a URL with the real pipeline (TWebPage over libhttp
  and libtls on host sockets with the host's roots, the layout sink,
  page scripting, the event loop driven like the web view), waits for
  the load event and quiet (or the timeout), and writes what is asked:

    webbrowse [options] URL

    -o FILE.png    a PNG of the viewport (--full: the whole page)
    -w WIDTH       viewport width in CSS pixels (1280)
    -h HEIGHT      viewport height (800)
    -s SCALE       device pixel ratio (1)
    -y OFFSET      scroll the viewport down this far before painting
    --resize WxH   resize the viewport once the page is quiet, then wait again
    --full         paint the whole document height (up to 30000 px)
    -l FILE        the layout tree ("-": standard output)
    --dom FILE     the document serialized as HTML ("-": standard output)
    -c             console messages
    -n             network requests (timing, status, protocol, bytes)
    --live         each request as it ends, on standard error
    -p             time in each phase (parse, style, layout, paint, script)
    -m             peak memory
    -t SECONDS     give up after this long (60)
    -q MS          quiet time after load that counts as done (500)
    --stall SECONDS  the watchdog reports a page thread stuck this long (5)
    --no-script    scripting off
    -e JS          evaluate JS once the page is quiet; print the result
    -f FONTDIR     font directory (userland/fonts)
    --hover N      once quiet, move the pointer down the viewport in N steps
                   (:hover on the chain under it) and time each move
    --profile      sample the page thread every millisecond; print the
                   functions it spent its time in
    -v             progress on standard error

  Exit status: 0 loaded, 1 navigation failed, 2 timed out, 3 hung
  (the watchdog gave up).
}
program WebBrowse;

{$mode objfpc}
{$H+}

uses
  cthreads,
  SysUtils,
  Web.Bindings.Context,
  WebBrowse.Session;

var
  Options: TBrowseOptions;
  Index: Integer;
  Argument: string;

procedure Usage;
begin
  WriteLn(StdErr, 'usage: webbrowse [-o OUT.png] [-w W] [-h H] [-s SCALE] [-y Y] [--full] [-l FILE] [--dom FILE] [-c] [-n]');
  WriteLn(StdErr, '         [--live] [-p] [-m] [-t SECONDS] [-q MS] [--stall S] [--no-script] [-e JS] [-f FONTDIR] [-v] URL');
  Halt(2);
end;

function NextArgument: string;
begin
  if Index >= ParamCount then
    Usage;
  Inc(Index);
  Result := ParamStr(Index);
end;

begin
  Options := DefaultBrowseOptions;
  Index := 1;
  while Index <= ParamCount do
  begin
    Argument := ParamStr(Index);
    if Argument = '-o' then
      Options.PngFile := NextArgument
    else if Argument = '-w' then
      Options.Width := StrToFloatDef(NextArgument, 1280)
    else if Argument = '-h' then
      Options.Height := StrToFloatDef(NextArgument, 800)
    else if Argument = '-s' then
      Options.Scale := StrToFloatDef(NextArgument, 1)
    else if Argument = '-y' then
      Options.ScrollY := StrToFloatDef(NextArgument, 0)
    else if Argument = '--resize' then
    begin
      Argument := NextArgument;
      Options.ResizeWidth := StrToFloatDef(Copy(Argument, 1, Pos('x', Argument) - 1), 0);
      Options.ResizeHeight := StrToFloatDef(Copy(Argument, Pos('x', Argument) + 1, MaxInt), 0);
    end
    else if Argument = '--full' then
      Options.WholePage := True
    else if Argument = '-l' then
      Options.LayoutFile := NextArgument
    else if Argument = '--dom' then
      Options.DomFile := NextArgument
    else if Argument = '-c' then
      Options.ShowConsole := True
    else if Argument = '-n' then
      Options.ShowNetwork := True
    else if Argument = '--live' then
      Options.LiveNetwork := True
    else if Argument = '-p' then
      Options.ShowPhases := True
    else if Argument = '-m' then
      Options.ShowMemory := True
    else if Argument = '-t' then
      Options.TimeoutSeconds := StrToFloatDef(NextArgument, 60)
    else if Argument = '-q' then
      Options.QuietMilliseconds := StrToFloatDef(NextArgument, 500)
    else if Argument = '--stall' then
      Options.StallSeconds := StrToIntDef(NextArgument, 5)
    else if Argument = '--no-script' then
      Options.Scripting := False
    else if Argument = '-e' then
      Options.EvalSource := NextArgument
    else if Argument = '-f' then
      Options.FontDirectory := NextArgument
    else if Argument = '--hover' then
      Options.HoverMoves := StrToIntDef(NextArgument, 0)
    else if Argument = '--profile' then
      Options.Profile := True
    else if Argument = '-v' then
      Options.Verbose := True
    else if (Argument <> '') and (Argument[1] = '-') then
      Usage
    else if Options.Url = '' then
      Options.Url := Argument
    else
      Usage;
    Inc(Index);
  end;
  if Options.Url = '' then
    Usage;
  { JS_GC_STRESS: the script engines collect every 16 KiB (finds values
    the collector does not see). }
  if GetEnvironmentVariable('JS_GC_STRESS') <> '' then
    ContextHeapThreshold := 16 * 1024;
  Halt(RunBrowse(Options));
end.
