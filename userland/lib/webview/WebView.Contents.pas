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

{ Everything in libwebview.so (the build compiles this unit). }
unit WebView.Contents;

{$mode objfpc}
{$H+}

interface

uses
  WebView.Types,
  WebView.Network,
  WebView.Zoom,
  WebView.Sites,
  WebView.TextIndex,
  WebView.SelectionMapping,
  WebView.Elements,
  WebView.Forms,
  WebView.PageInfo,
  WebView.Engine,
  WebView.ContentProcess,
  WebView.NetworkService,
  WebView.NetworkSockets,
  WebView.ContentIo,
  WebView.ContentProcesses,
  WebView.PromptSheet,
  WebView.RecoveryPanels,
  WebView.RemoteFrames,
  WebView.Control;

implementation

end.
