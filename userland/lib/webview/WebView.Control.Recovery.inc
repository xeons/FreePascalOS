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

{ WebView.Control: a crashed or hung content process, and the page's
  dialogs (modal for this view only). }

const
  { The slow script watchdog ending this many scripts within the window
    below counts as a page that will not respond. }
  InterruptsForHang = 3;
  InterruptWindowMilliseconds = 60000;

procedure TWebView.ShowCrashPanel(const Reason: string);
begin
  if FCrashPanel = nil then
  begin
    FCrashPanel := TCrashPanel.Create(Self);
    FCrashPanel.OnReload := @CrashReloadClicked;
  end;
  FCrashPanel.SetReason(Reason);
  RequestLayout;
  Invalidate;
end;

procedure TWebView.HideCrashPanel;
begin
  if FCrashPanel = nil then
    Exit;
  FreeAndNil(FCrashPanel);
  RequestLayout;
  Invalidate;
end;

procedure TWebView.CrashReloadClicked(Sender: TControl);
begin
  HideCrashPanel;
  Reload;
end;

procedure TWebView.ShowHangBar(const Value: string);
begin
  if FHangBar = nil then
  begin
    FHangBar := THangBar.Create(Self);
    FHangBar.OnWait := @HangWaitClicked;
    FHangBar.OnStop := @HangStopClicked;
  end;
  FHangBar.SetMessage(Value);
  FHangWaitUntil := 0;
  RequestLayout;
  Invalidate;
end;

procedure TWebView.HideHangBar;
begin
  if FHangBar = nil then
    Exit;
  FreeAndNil(FHangBar);
  RequestLayout;
  Invalidate;
end;

procedure TWebView.HangWaitClicked(Sender: TControl);
var
  Timeout: QWord;
begin
  HideHangBar;
  FInterruptTimes := nil;
  Timeout := ContentProcesses.HangTimeoutMilliseconds;
  if Timeout = 0 then
    Timeout := DefaultHangTimeoutMilliseconds;
  { Asked again if it still does not answer by then. }
  FHangWaitUntil := GetTickCount64 + Timeout;
  TellProcessEvent('wait', 0);
end;

procedure TWebView.HangStopClicked(Sender: TControl);
begin
  HideHangBar;
  TellProcessEvent('stop', 0);
  TerminateContentProcess;
end;

procedure TWebView.NoteScriptInterrupted;
var
  Now: QWord;
  Index, Recent: Integer;
begin
  Now := GetTickCount64;
  Insert(Now, FInterruptTimes, Length(FInterruptTimes));
  Recent := 0;
  for Index := 0 to High(FInterruptTimes) do
    if Now - FInterruptTimes[Index] <= InterruptWindowMilliseconds then
      Inc(Recent);
  TellProcessEvent('script-interrupted', Recent);
  if (Recent >= InterruptsForHang) and (FHangBar = nil) then
    ShowHangBar('A script on this page keeps running too long.');
end;

{ ---- dialogs ---- }

procedure TWebView.TakeDialog(Message: TIpcMessage);
var
  Request: TIpcDialogRequest;
  Answer: TIpcDialogAnswer;
  Origin: string;
begin
  Answer := Default(TIpcDialogAnswer);
  if Message.Kind = IpcConfirmUnload then
  begin
    if Assigned(FOnConfirmUnload) then
    begin
      Answer.Accepted := FOnConfirmUnload(Self);
      SendToProcess(IpcReply, EncodeDialogAnswer(Answer), Message.RequestId);
      Exit;
    end;
    if Assigned(FOnScriptDialog) then
      FOnScriptDialog(Self, 'leave', '');
    OpenSheet(SheetLeavePage, '', '', Message.RequestId, Message.Kind);
    Exit;
  end;
  Request := DecodeDialogRequest(Message.Payload);
  case Request.Kind of
    DialogAlert:
      if Assigned(FOnScriptAlert) then
      begin
        FOnScriptAlert(Self, Request.Message);
        Answer.Accepted := True;
        SendToProcess(IpcReply, EncodeDialogAnswer(Answer), Message.RequestId);
        Exit;
      end;
    DialogConfirm:
      if Assigned(FOnScriptConfirm) then
      begin
        Answer.Accepted := FOnScriptConfirm(Self, Request.Message);
        SendToProcess(IpcReply, EncodeDialogAnswer(Answer), Message.RequestId);
        Exit;
      end;
    DialogPrompt:
      if Assigned(FOnScriptPrompt) then
      begin
        Answer.Accepted := FOnScriptPrompt(Self, Request.Message, Request.DefaultText, Answer.Text);
        SendToProcess(IpcReply, EncodeDialogAnswer(Answer), Message.RequestId);
        Exit;
      end;
  end;
  Origin := SiteHost(RemoteSite);
  if Origin = '' then
    Origin := 'This page';
  case Request.Kind of
    DialogAlert:
      begin
        if Assigned(FOnScriptDialog) then
          FOnScriptDialog(Self, 'alert', Request.Message);
        OpenSheet(SheetAlert, Request.Message, '', Message.RequestId, Message.Kind);
      end;
    DialogConfirm:
      begin
        if Assigned(FOnScriptDialog) then
          FOnScriptDialog(Self, 'confirm', Request.Message);
        OpenSheet(SheetConfirm, Request.Message, '', Message.RequestId, Message.Kind);
      end;
  else
    begin
      if Assigned(FOnScriptDialog) then
        FOnScriptDialog(Self, 'prompt', Request.Message);
      OpenSheet(SheetPrompt, Request.Message, Request.DefaultText, Message.RequestId, Message.Kind);
    end;
  end;
end;

procedure TWebView.OpenSheet(Kind: TPromptSheetKind; const Message, Default: string; RequestId: LongWord;
  RequestKind: Word);
var
  Origin: string;
begin
  CloseSheet;
  Origin := SiteHost(RemoteSite);
  if Origin = '' then
    Origin := 'This page';
  FSheet := TPromptSheet.CreateSheet(Self, Kind, Origin, Message, Default);
  FSheet.OnAnswered := @SheetAnswered;
  FSheetRequestId := RequestId;
  FSheetRequestKind := RequestKind;
  RequestLayout;
  if Focused or IsShown then
    FSheet.TakeFocus;
  Invalidate;
end;

procedure TWebView.SheetAnswered(Sheet: TPromptSheet; Accepted: Boolean; const Value: string);
var
  Answer: TIpcDialogAnswer;
begin
  Answer.Accepted := Accepted;
  Answer.Text := Value;
  SendToProcess(IpcReply, EncodeDialogAnswer(Answer), FSheetRequestId);
  FSheetRequestId := 0;
  { Not freed from inside its own event: released after it returns. }
  FSheet.Visible := False;
  FSheet := nil;
  PostMessage(Self, MessageWebViewReleaseSheet, PtrInt(Sheet), 0);
  RequestLayout;
  SetFocus;
  Invalidate;
end;

procedure TWebView.ReceiveMessage(var Message: TPostedMessage);
begin
  if Message.Code = MessageWebViewReleaseSheet then
  begin
    TObject(Message.Parameter1).Free;
    RequestLayout;
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

procedure TWebView.CloseSheet;
begin
  if FSheet = nil then
    Exit;
  FreeAndNil(FSheet);
  FSheetRequestId := 0;
  RequestLayout;
  Invalidate;
end;
