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

{ WebView.Control: what the navigable tells the view. }

type
  TViewObserver = class(TNavigableObserver)
  public
    View: TWebView;
    procedure LocationChanged(Navigable: TNavigable; const Url: string); override;
    procedure TitleChanged(Navigable: TNavigable; const Title: string); override;
    procedure LoadingStateChanged(Navigable: TNavigable; State: TLoadingState); override;
    procedure DocumentChanged(Navigable: TNavigable; Document: TDocument; Window: TWebWindow); override;
    procedure FaviconChanged(Navigable: TNavigable; const Url: string; Image: TImage); override;
    procedure HistoryChanged(Navigable: TNavigable); override;
    procedure ScrollToFragment(Navigable: TNavigable; Element: TElement); override;
    procedure RestoreScrollPosition(Navigable: TNavigable; X, Y: Double); override;
    function ConfirmUnload(Navigable: TNavigable): Boolean; override;
    procedure DownloadRequested(Navigable: TNavigable; constref Download: TDownloadInfo); override;
    procedure NavigationFailed(Navigable: TNavigable; const Url, Reason: string); override;
  end;

procedure TViewObserver.LocationChanged(Navigable: TNavigable; const Url: string);
begin
  View.NavigableLocationChanged(Url);
end;

procedure TViewObserver.TitleChanged(Navigable: TNavigable; const Title: string);
begin
  View.NavigableTitleChanged(Title);
end;

procedure TViewObserver.LoadingStateChanged(Navigable: TNavigable; State: TLoadingState);
begin
  View.NavigableLoadingStateChanged(State);
end;

procedure TViewObserver.DocumentChanged(Navigable: TNavigable; Document: TDocument; Window: TWebWindow);
begin
  View.AdoptDocument(Document);
end;

procedure TViewObserver.FaviconChanged(Navigable: TNavigable; const Url: string; Image: TImage);
begin
  View.NavigableFaviconChanged(Image);
end;

procedure TViewObserver.HistoryChanged(Navigable: TNavigable);
begin
  View.NavigableHistoryChanged;
end;

procedure TViewObserver.ScrollToFragment(Navigable: TNavigable; Element: TElement);
begin
  View.NavigableScrollToFragment(Element);
end;

procedure TViewObserver.RestoreScrollPosition(Navigable: TNavigable; X, Y: Double);
begin
  View.NavigableRestoreScrollPosition(X, Y);
end;

function TViewObserver.ConfirmUnload(Navigable: TNavigable): Boolean;
begin
  Result := View.NavigableConfirmUnload;
end;

procedure TViewObserver.DownloadRequested(Navigable: TNavigable; constref Download: TDownloadInfo);
begin
  View.NavigableDownloadRequested(Download);
end;

procedure TViewObserver.NavigationFailed(Navigable: TNavigable; const Url, Reason: string);
begin
  View.NavigableFailed(Url, Reason);
end;
