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
  WebLoadTest - checks libweb's loading side on the host (make
  web-load-test): the event loop and timers, the fetch layer, document
  loading, subresources and navigation.

  Prints one line per check and the totals; exits with 1 if any failed.
}
program WebLoadTest;

{$mode objfpc}
{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  TestChecks,
  WebLoadTest.EventLoop,
  WebLoadTest.FetchRules,
  WebLoadTest.Fetching,
  WebLoadTest.Loading,
  WebLoadTest.Rendering,
  WebLoadTest.Scripting,
  WebLoadTest.Editing,
  WebLoadTest.Frames,
  SysUtils,
  Web.Bindings.Context,
  Web.Navigation.Pages;

begin
  { JS_GC_STRESS: the script engines collect every 16 KiB. }
  if GetEnvironmentVariable('JS_GC_STRESS') <> '' then
    ContextHeapThreshold := 16 * 1024;
  { "editing": only the editing fuzz test (to debug it). }
  if ParamStr(1) = 'editing' then
  begin
    RunEditingTests;
    FinishChecks('web load test (editing)');
    Exit;
  end;
  RunEventLoopTests;
  RunFetchRuleTests;
  RunFetchingTests;
  RunLoadingTests;
  RunRenderingTests;
  RunScriptingTests;
  RunFrameTests;
  RunEditingTests;
  FinishChecks('web load test');
end.
