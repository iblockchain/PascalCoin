unit UWIZSendPASC;

{$mode delphi}

{ Copyright (c) 2018 Sphere 10 Software (http://www.sphere10.com/)

  Distributed under the MIT software license, see the accompanying file LICENSE
  or visit http://www.opensource.org/licenses/mit-license.php.

  Acknowledgements:
  Ugochukwu Mmaduekwe - main developer
  Herman Schoenfeld - designer <herman@sphere10.com>: added grid-based layout
}

interface

uses
  Classes, SysUtils, Forms, Dialogs, UCrypto, UWizard, UAccounts, LCLType, UWIZModels;

type

  { TWIZSendPASCWizard }

  TWIZSendPASCWizard = class(TWizard<TWIZOperationsModel>)
  private
    function UpdatePayload(const SenderAccount: TAccount; var errors: string): boolean;
    function UpdateOperationOptions(var errors: string): boolean;
    function UpdateOpTransaction(const SenderAccount: TAccount; var DestAccount: TAccount; var amount: int64; var errors: string): boolean;
    procedure SendPASC();
  public
    constructor Create(AOwner: TComponent); override;
    function DetermineHasNext: boolean; override;
    function DetermineHasPrevious: boolean; override;
    function FinishRequested(out message: ansistring): boolean; override;
    function CancelRequested(out message: ansistring): boolean; override;
  end;

implementation

uses
  UBlockChain,
  UOpTransaction,
  UNode,
  UConst,
  UWallet,
  UECIES,
  UAES,
  UWIZSendPASC_ConfirmSender,
  UWIZSendPASC_Confirmation;

{ TWIZSendPASCWizard }

function TWIZSendPASCWizard.UpdateOperationOptions(var errors: string): boolean;
var
  iAcc, iWallet: integer;
  sender_account, dest_account: TAccount;
  wk: TWalletKey;
  e: string;
  amount: int64;
begin
  Result := False;
  errors := '';
  if not Assigned(TWallet.Keys) then
  begin
    errors := 'No wallet keys';
    Exit;
  end;

  if Length(Model.Account.SelectedAccounts) = 0 then
  begin
    errors := 'No sender account';
    Exit;
  end
  else
  begin

    for iAcc := Low(Model.Account.SelectedAccounts) to High(Model.Account.SelectedAccounts) do
    begin
      sender_account := Model.Account.SelectedAccounts[iAcc];
      iWallet := TWallet.Keys.IndexOfAccountKey(sender_account.accountInfo.accountKey);
      if (iWallet < 0) then
      begin
        errors := 'Private key of account ' +
          TAccountComp.AccountNumberToAccountTxtNumber(sender_account.account) +
          ' not found in wallet';
        Exit;
      end;
      wk := TWallet.Keys.Key[iWallet];
      if not assigned(wk.PrivateKey) then
      begin
        if wk.CryptedKey <> '' then
        begin
          // TODO: handle unlocking of encrypted wallet here
          errors := 'Wallet is password protected. Need password';
        end
        else
        begin
          errors := 'Only public key of account ' +
            TAccountComp.AccountNumberToAccountTxtNumber(sender_account.account) +
            ' found in wallet. You cannot operate with this account';
        end;
        Exit;
      end;
    end;
  end;

  Result := UpdateOpTransaction(Model.Account.SelectedAccounts[0], dest_account, amount, errors);
  UpdatePayload(sender_account, e);
end;

function TWIZSendPASCWizard.UpdateOpTransaction(const SenderAccount: TAccount; var DestAccount: TAccount; var amount: int64; var errors: string): boolean;
var
  c: cardinal;
begin
  Result := False;
  errors := '';

  DestAccount := Model.SendPASC.DestinationAccount;

  case Model.SendPASC.SendPASCMode of
    akaAllBalance:
    begin
      amount := 0; // ALL BALANCE
    end;

    akaSpecifiedAmount:
    begin
      amount := Model.SendPASC.SingleAmountToSend;
    end;
  end;

  if DestAccount.account = SenderAccount.account then
  begin
    errors := 'Sender and dest account are the same';
    Exit;
  end;

  case Model.SendPASC.SendPASCMode of
    akaSpecifiedAmount:
    begin
      if (SenderAccount.balance < (amount + Model.Fee.SingleOperationFee)) then
      begin
        errors := 'Insufficient funds';
        Exit;
      end;
    end;
  end;

  Result := True;
end;

procedure TWIZSendPASCWizard.SendPASC();
var
  _V2, dooperation: boolean;
  iAcc, i: integer;
  _totalamount, _totalfee, _totalSignerFee, _amount, _fee: int64;
  _signer_n_ops: cardinal;
  operationstxt, operation_to_string, errors, auxs: string;
  wk: TWalletKey;
  ops: TOperationsHashTree;
  op: TPCOperation;
  account, destAccount: TAccount;
begin
  if not Assigned(TWallet.Keys) then
    raise Exception.Create('No wallet keys');
  if not UpdateOperationOptions(errors) then
    raise Exception.Create(errors);
  ops := TOperationsHashTree.Create;
  try
    _V2 := TNode.Node.Bank.SafeBox.CurrentProtocol >= CT_PROTOCOL_2;
    _totalamount := 0;
    _totalfee := 0;
    _totalSignerFee := 0;
    _signer_n_ops := 0;
    operationstxt := '';
    operation_to_string := '';
    for iAcc := Low(Model.Account.SelectedAccounts) to High(Model.Account.SelectedAccounts) do
    begin
      op := nil;
      account := Model.Account.SelectedAccounts[iAcc];
      if not UpdatePayload(account, errors) then
      begin
        raise Exception.Create('Error encoding payload of sender account ' +
          TAccountComp.AccountNumberToAccountTxtNumber(account.account) + ': ' + errors);
      end;
      i := TWallet.Keys.IndexOfAccountKey(account.accountInfo.accountKey);
      if i < 0 then
      begin
        raise Exception.Create('Sender account private key not found in Wallet');
      end;

      wk := TWallet.Keys.Key[i];
      dooperation := True;
      // Default fee
      if account.balance > uint64(Model.Fee.SingleOperationFee) then
        _fee := Model.Fee.SingleOperationFee
      else
        _fee := account.balance;

      if not UpdateOpTransaction(account, destAccount, _amount, errors) then
        raise Exception.Create(errors);

      if account.balance > 0 then
      begin
        if account.balance > Model.Fee.SingleOperationFee then
        begin
          case Model.SendPASC.SendPASCMode of
            akaAllBalance:
            begin
              _amount := account.balance - Model.Fee.SingleOperationFee;
              _fee := Model.Fee.SingleOperationFee;
            end;
          end;
        end
        else
        begin
          _amount := account.balance;
          _fee := 0;
        end;
      end
      else
      begin
        dooperation := False;
      end;

      if dooperation then
      begin
        op := TOpTransaction.CreateTransaction(
          account.account, account.n_operation + 1, destAccount.account,
          wk.PrivateKey, _amount, _fee, Model.Payload.EncodedBytes);
        Inc(_totalamount, _amount);
        Inc(_totalfee, _fee);
      end;
      operationstxt := 'Transaction to ' + TAccountComp.AccountNumberToAccountTxtNumber(
        destAccount.account);

      if Assigned(op) and (dooperation) then
      begin
        ops.AddOperationToHashTree(op);
        if operation_to_string <> '' then
          operation_to_string := operation_to_string + #10;
        operation_to_string := operation_to_string + op.ToString;
      end;
      FreeAndNil(op);
    end;

    if (ops.OperationsCount = 0) then
      raise Exception.Create('No valid operation to execute');

    if (Length(Model.Account.SelectedAccounts) > 1) then
    begin
      auxs := 'Total amount that dest will receive: ' + TAccountComp.FormatMoney(
        _totalamount) + #10;
      if Application.MessageBox(
        PChar('Execute ' + IntToStr(Length(Model.Account.SelectedAccounts)) +
        ' operations?' + #10 + 'Operation: ' + operationstxt + #10 +
        auxs + 'Total fee: ' + TAccountComp.FormatMoney(_totalfee) +
        #10 + #10 + 'Note: This operation will be transmitted to the network!'),
        PChar(Application.Title), MB_YESNO + MB_ICONINFORMATION + MB_DEFBUTTON2) <>
        idYes then
      begin
        Exit;
      end;
    end
    else
    begin
      if Application.MessageBox(PChar('Execute this operation:' +
        #10 + #10 + operation_to_string + #10 + #10 +
        'Note: This operation will be transmitted to the network!'),
        PChar(Application.Title), MB_YESNO + MB_ICONINFORMATION + MB_DEFBUTTON2) <>
        idYes then
      begin
        Exit;
      end;
    end;
    i := TNode.Node.AddOperations(nil, ops, nil, errors);
    if (i = ops.OperationsCount) then
    begin
      operationstxt := 'Successfully executed ' + IntToStr(i) +
        ' operations!' + #10 + #10 + operation_to_string;
      if i > 1 then
      begin
        //  with TFRMMemoText.Create(Self) do
        //    try
        //      InitData(Application.Title, operationstxt);
        //      ShowModal;
        //    finally
        //      Free;
        //    end;
        ShowMessage(operationstxt);
      end
      else
      begin
        Application.MessageBox(
          PChar('Successfully executed ' + IntToStr(i) + ' operations!' +
          #10 + #10 + operation_to_string),
          PChar(Application.Title), MB_OK + MB_ICONINFORMATION);
      end;
      // ModalResult := mrOk;
    end
    else if (i > 0) then
    begin
      operationstxt := 'One or more of your operations has not been executed:' +
        #10 + 'Errors:' + #10 + errors + #10 + #10 +
        'Total successfully executed operations: ' + IntToStr(i);
      //with TFRMMemoText.Create(Self) do
      //  try
      //    InitData(Application.Title, operationstxt);
      //    ShowModal;
      //  finally
      //    Free;
      //  end;
      //ModalResult := mrOk;
      ShowMessage(operationstxt);
    end
    else
    begin
      raise Exception.Create(errors);
    end;

  finally
    ops.Free;
  end;
end;

function TWIZSendPASCWizard.UpdatePayload(const SenderAccount: TAccount; var errors: string): boolean;
var
  valid: boolean;
  payload_encrypted, payload_u: string;
  account: TAccount;
begin
  valid := False;
  payload_encrypted := '';
  Model.Payload.EncodedBytes := '';
  errors := 'Unknown error';
  payload_u := Model.Payload.Content;

  try
    if (payload_u = '') then
    begin
      valid := True;
      Exit;
    end;
    case Model.Payload.Mode of

      akaEncryptWithSender:
      begin
        // Use sender
        errors := 'Error encrypting';
        account := SenderAccount;
        payload_encrypted := ECIESEncrypt(account.accountInfo.accountKey, payload_u);
        valid := payload_encrypted <> '';
      end;

      akaEncryptWithReceiver:
      begin
        // With dest public key
        errors := 'Error encrypting';
        account := Model.SendPASC.DestinationAccount;
        payload_encrypted := ECIESEncrypt(account.accountInfo.accountKey, payload_u);
        valid := payload_encrypted <> '';
      end;

      akaEncryptWithPassword:
      begin
        payload_encrypted := TAESComp.EVP_Encrypt_AES256(
          payload_u, Model.Payload.Password);
        valid := payload_encrypted <> '';
      end;

      akaNotEncrypt:
      begin
        payload_encrypted := payload_u;
        valid := True;
      end

      else
      begin
        raise Exception.Create('Invalid Encryption Selection');
      end;
    end;

  finally
    if valid then
    begin
      if length(payload_encrypted) > CT_MaxPayloadSize then
      begin
        valid := False;
        errors := 'Payload size is bigger than ' + IntToStr(CT_MaxPayloadSize) +
          ' (' + IntToStr(length(payload_encrypted)) + ')';
      end;

    end;
    Model.Payload.EncodedBytes := payload_encrypted;
    Result := valid;
  end;

end;

constructor TWIZSendPASCWizard.Create(AOwner: TComponent);
begin
  inherited Create(AOwner, [TWIZSendPASC_ConfirmSender, TWIZSendPASC_Confirmation]);
  TitleText := 'Send PASC';
  FinishText := 'Send PASC';
end;

function TWIZSendPASCWizard.DetermineHasNext: boolean;
begin
  Result := not (CurrentScreen is TWIZSendPASC_Confirmation);
end;

function TWIZSendPASCWizard.DetermineHasPrevious: boolean;
begin
  Result := inherited DetermineHasPrevious;
end;

function TWIZSendPASCWizard.FinishRequested(out message: ansistring): boolean;
begin
  // Execute the PASC Sending here
  try
    Result := True;
    SendPASC();
  except
    On E: Exception do
    begin
      Result := False;
      message := E.ToString;
    end;
  end;
end;

function TWIZSendPASCWizard.CancelRequested(out message: ansistring): boolean;
begin
  Result := True;
end;

end.
