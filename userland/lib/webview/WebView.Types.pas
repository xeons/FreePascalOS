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
  of: where a clicked link goes, what is under a context menu, the
  commands of the view's own context menu, the session history and
  Page Info.
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
    { An img's URL (resolved), '' none. }
    ImageUrl: string;
    SelectedText: string;
    InTextField: Boolean;
    { The nearest background-image of the element or its ancestors
      (resolved), '' none. }
    BackgroundImageUrl: string;
    { A text field, text area or contenteditable element: Cut, Paste,
      Undo make sense. }
    IsEditable: Boolean;
    { The URL of the frame's document when the point is in a frame, ''
      otherwise. }
    FrameUrl: string;
    { There is something to copy (a selection). }
    CanCopy: Boolean;
  end;

  { An entry of a view's session history (WebView.Control's
    HistoryEntries, oldest first). }
  TWebHistoryEntry = record
    Url, Title: string;
  end;
  TWebHistoryList = array of TWebHistoryEntry;

  { Page Info's media: Kind is 'Image', 'Background', 'Icon' or 'Input
    image'; the size is CSS pixels as shown (0 when not laid out). }
  TWebMediaItem = record
    Url, Kind, AltText: string;
    Width, Height: LongInt;
  end;
  TWebMediaList = array of TWebMediaItem;

  { A meta element's name (or http-equiv, or property) and content. }
  TWebMetaItem = record
    Name, Content: string;
  end;
  TWebMetaList = array of TWebMetaItem;

  TWebPageInfo = record
    Url, Title, Referrer, ContentType, Encoding: string;
    { 'Standards compliance mode' or 'Quirks mode'. }
    RenderMode: string;
    { The response's Last-Modified field as sent, '' none. }
    LastModified: string;
    Meta: TWebMetaList;
    Media: TWebMediaList;
    FormCount, LinkCount: LongInt;
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
