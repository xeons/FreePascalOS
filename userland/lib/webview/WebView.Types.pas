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
  What the web view (WebView.Control) and the page engine behind it
  (WebView.Engine, in a content process or in the program) both speak
  of: where a clicked link goes, what is under a context menu, and the
  commands of the view's own context menu.
}
unit WebView.Types;

{$mode objfpc}
{$H+}

interface

type
  { Background: a middle click or Ctrl+click; a new tab: a target. }
  TLinkDisposition = (LinkInView, LinkInNewTab, LinkInBackgroundTab, LinkInNewWindow);

  TWebContextInfo = record
    { The control's own pixels. }
    X, Y: LongInt;
    FromKeyboard: Boolean;
    LinkUrl: string;
    LinkText: string;
    ImageUrl: string;
    SelectedText: string;
    InTextField: Boolean;
  end;

  { Where a view's pages run: in a content process of their site (the
    default: a page that crashes or hangs takes only its own tabs with
    it), or in the program itself (simple HTML a program shows; the page
    engine's objects - Page, Navigable, Document - are reachable then). }
  TWebViewProcessModel = (ProcessModelSeparate, ProcessModelInProcess);

const
  { Commands of the view's own context menu (IpcViewCommand). }
  ViewCommandBack = 1;
  ViewCommandForward = 2;
  ViewCommandReload = 3;
  ViewCommandCopy = 4;
  ViewCommandCopyLink = 5;
  ViewCommandSelectAll = 6;
  { Asks for the page's whole text (answered with IpcPageText). }
  ViewCommandPageText = 7;
  { Test only: the content process crashes, or hangs (a loop the
    watchdog does not end). }
  ViewCommandCrash = 8;
  ViewCommandHang = 9;

implementation

end.
