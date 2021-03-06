unit UDataSources;

{$mode delphi}
{$modeswitch nestedprocvars}

interface

uses
  Classes, SysUtils, UAccounts, UNode, UBlockchain, UCoreObjects,
  UCommon, UMemory, UConst, UCommon.Data,
  UCommon.Collections, Generics.Collections, Generics.Defaults, syncobjs;

type

  { TAccountsDataSourceBase }

  TAccountsDataSourceBase = class(TCustomDataSource<TAccount>)
    protected
      function GetColumns : TDataColumns; override;
    public
      function GetItemField(constref AItem: TAccount; const ABindingName : AnsiString) : Variant; override;
  end;

  { TAccountsDataSource }

  TAccountsDataSource = class(TAccountsDataSourceBase)
    protected
      FIncludePending : boolean;
      FKeys : TSortedHashSet<TAccountKey>;
      function GetFilterKeys : TArray<TAccountKey>;
      procedure SetFilterKeys (const AKeys : TArray<TAccountKey>);
    public
      property IncludePending : boolean read FIncludePending write FIncludePending;
      property FilterKeys : TArray<TAccountKey> read GetFilterKeys write SetFilterKeys;
      constructor Create(AOwner: TComponent); override;
      destructor Destroy; override;
      procedure FetchAll(const AContainer : TList<TAccount>); override;
  end;

  { TMyAccountsDataSource }

  TMyAccountsDataSource = class(TAccountsDataSource)
  public
      procedure FetchAll(const AContainer : TList<TAccount>); override;
  end;

  { TOperationsDataSourceBase }

  TOperationsDataSourceBase = class(TCustomDataSource<TOperationResume>)
    private
      FStart, FEnd : Cardinal;
      function GetTimeSpan : TTimeSpan;
      procedure SetTimeSpan(const ASpan : TTimeSpan);
    protected
      function GetColumns : TDataColumns;  override;
    public
      constructor Create(AOwner: TComponent); override;
      property TimeSpan : TTimeSpan read GetTimeSpan write SetTimeSpan;
      property StartBlock : Cardinal read FStart write FStart;
      property EndBlock : Cardinal read FEnd write FEnd;
      function GetItemField(constref AItem: TOperationResume; const ABindingName : AnsiString) : Variant; override;
  end;

  { TAccountsOperationsDataSource }

  TAccountsOperationsDataSource = class(TOperationsDataSourceBase)
    private
      FAccounts : TSortedHashSet<Cardinal>;
      function GetAccounts : TArray<Cardinal> ;
      procedure SetAccounts(const AAccounts : TArray<Cardinal>);
    public
      constructor Create(AOwner: TComponent); override;
      destructor Destroy; override;
      property Accounts : TArray<Cardinal> read GetAccounts write SetAccounts;
      procedure FetchAll(const AContainer : TList<TOperationResume>); override;
  end;

  { TPendingOperationsDataSource }

  TPendingOperationsDataSource = class(TOperationsDataSourceBase)
    public
      procedure FetchAll(const AContainer : TList<TOperationResume>); override;
  end;

  { TOperationsDataSource }

  TOperationsDataSource = class(TOperationsDataSourceBase)
    public
      procedure FetchAll(const AContainer : TList<TOperationResume>); override;
  end;

implementation

uses
  math, UCoreUtils, UWallet, UTime;

{ TAccountsDataSourceBase }

function TAccountsDataSourceBase.GetColumns : TDataColumns;
begin
  Result := TDataColumns.Create(
    TDataColumn.From('AccountNumber', true),
    TDataColumn.From('Account'),
    TDataColumn.From('Name'),
    TDataColumn.From('Display'),
    TDataColumn.From('Balance'),
    TDataColumn.From('BalanceDecimal'),
    TDataColumn.From('Key'),
    TDataColumn.From('Type'),
    TDataColumn.From('State'),
    TDataColumn.From('Price'),
    TDataColumn.From('PriceDecimal'),
    TDataColumn.From('LockedUntil')
  );
end;

function TAccountsDataSourceBase.GetItemField(constref AItem: TAccount; const ABindingName : AnsiString) : Variant;
var
  index : Integer;
begin
  if ABindingName = 'AccountNumber' then
    Result := AItem.account
  else if ABindingName = 'Account' then
    Result := AItem.AccountString
  else if ABindingName = 'Name' then
    Result := AItem.name
  else if ABindingName = 'Display' then
    Result := AItem.DisplayString
  else if ABindingName = 'Balance' then
    Result := AItem.Balance
  else if ABindingName = 'BalanceDecimal' then
    Result := TAccountComp.FormatMoneyDecimal(AItem.Balance)
  else if ABindingName = 'Key' then
    Result := TAccountComp.AccountPublicKeyExport(AItem.accountInfo.accountKey)
  else if ABindingName = 'Type' then
    Result := AItem.account_type
  else if ABindingName = 'State' then
    Result := AItem.accountInfo.state
  else if ABindingName = 'Price' then
    Result := AItem.accountInfo.price
  else if ABindingName = 'PriceDecimal' then
    Result := TAccountComp.FormatMoneyDecimal(AItem.accountInfo.price)
  else if ABindingName = 'LockedUntil' then
    Result := AItem.accountInfo.locked_until_block
  else raise Exception.Create(Format('Field not found "%s"', [ABindingName]));
end;

{ TAccountsDataSource }

constructor TAccountsDataSource.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FKeys := TSortedHashSet<TAccountKey>.Create(TAccountKeyComparer.Create, TAccountKeyEqualityComparer.Create);
end;

destructor TAccountsDataSource.Destroy;
begin
  FKeys.Free;
end;

function TAccountsDataSource.GetFilterKeys : TArray<TAccountKey>;
begin
  Result := FKeys.ToArray;
end;

procedure TAccountsDataSource.SetFilterKeys (const AKeys : TArray<TAccountKey>);
var i : Integer;
begin
  FKeys.Clear;
  for i := Low(AKeys) to High(AKeys) do
    FKeys.Add(AKeys[i]);
end;

procedure TAccountsDataSource.FetchAll(const AContainer : TList<TAccount>);
var
  i : integer;
  acc : TAccount;
  safeBox : TPCSafeBox;
begin
  safeBox := TNode.Node.Bank.SafeBox;
  safeBox.StartThreadSafe;
  try
   if FKeys.Count = 0 then
     for i := 0 to safeBox.AccountsCount - 1 do
       AContainer.Add(safeBox.Account(i)) // Load all accounts
   else
     for i := 0 to safeBox.AccountsCount - 1 do begin // Load key-matching accounts
       if FIncludePending then
         acc := TNode.Node.Operations.SafeBoxTransaction.Account(i)
       else
         acc := safeBox.Account(i);
       if FKeys.Contains(acc.accountInfo.accountKey) then
         AContainer.Add(acc)
     end;
  finally
   safeBox.EndThreadSave;
  end;
end;

{ TMyAccountsDataSource }

procedure TMyAccountsDataSource.FetchAll(const AContainer : TList<TAccount>);
var
  i : integer;
  LAccs : TArray<TAccount>;
begin
  LAccs := TWallet.Keys.AccountsKeyList.GetAccounts(FIncludePending);
  if FKeys.Count > 0 then begin
    for i := Low(LAccs) to High(LAccs) do
      if FKeys.Contains(LAccs[i].accountInfo.accountKey) then
        AContainer.Add(LAccs[i]);
  end else AContainer.AddRange(LAccs);
end;

{ TOperationsDataSourceBase }

constructor TOperationsDataSourceBase.Create(AOwner:TComponent);
var
  node : TNode;
begin
 inherited Create(AOwner);
 node := TNode.Node;
  if Assigned(Node) then begin
    FStart := 0;
    FEnd := node.Bank.BlocksCount - 1;
  end else begin
    FStart := 0;
    FEnd := 0;
  end;
end;

function TOperationsDataSourceBase.GetTimeSpan : TTimeSpan;
begin
  Result := TTimeSpan.FromSeconds( CT_NewLineSecondsAvg * (FEnd - FStart + 1) );
end;

procedure TOperationsDataSourceBase.SetTimeSpan(const ASpan : TTimeSpan);
var
  node : TNode;
begin
 node := TNode.Node;
 if Not Assigned(Node) then exit;
 FEnd := node.Bank.BlocksCount - 1;
 FStart := ClipValue(FEnd - (ASpan.TotalBlockCount + 1), 0, FEnd);
end;

function TOperationsDataSourceBase.GetColumns : TDataColumns;
begin
  Result := TDataColumns.Create(
    TDataColumn.From('OPHASH', true),
    TDataColumn.From('UnixTime'),
    TDataColumn.From('Time'),
    TDataColumn.From('Block'),
    TDataColumn.From('Index'),
    TDataColumn.From('BlockLocation'),
    TDataColumn.From('BlockLocationSortable'),
    TDataColumn.From('Account'),
    TDataColumn.From('AccountNumber'),
    TDataColumn.From('Type'),
    TDataColumn.From('SubType'),
    TDataColumn.From('Amount'),
    TDataColumn.From('AmountDecimal'),
    TDataColumn.From('Fee'),
    TDataColumn.From('FeeDecimal'),
    TDataColumn.From('Balance'),
    TDataColumn.From('BalanceDecimal'),
    TDataColumn.From('Payload'),
    TDataColumn.From('Description')
  );
end;

function TOperationsDataSourceBase.GetItemField(constref AItem: TOperationResume; const ABindingName : AnsiString) : Variant;
var
  index : Integer;
begin
  if ABindingName = 'OPHASH' then
    Result := TPCOperation.OperationHashAsHexa(AItem.OperationHash)
  else if ABindingName = 'UnixTime' then
    Result := AItem.Time
  else if ABindingName = 'Time' then
    Result := UnixTimeToLocalStr(AItem.time)
  else if ABindingName = 'Block' then
    Result := AItem.Block
  else if ABindingName = 'Index' then
    Result := AItem.NOpInsideBlock
  else if ABindingName = 'BlockLocation' then
    Result := IIF(AItem.OpType <> CT_PseudoOp_Reward, Inttostr(AItem.Block) + '/' + Inttostr(AItem.NOpInsideBlock+1), Inttostr(AItem.Block))
  else if ABindingName = 'BlockLocationSortable' then
    Result := IIF(AItem.OpType <> CT_PseudoOp_Reward, UInt64(AItem.Block) * 4294967296 + UInt32(AItem.NOpInsideBlock), 0)  // number pattern = [block][opindex]
  else if ABindingName = 'Account' then
    Result := TAccountComp.AccountNumberToAccountTxtNumber(AItem.AffectedAccount)
  else if ABindingName = 'AccountNumber' then
    Result := AItem.AffectedAccount
  else if ABindingName = 'Type' then
    Result := AItem.OpType
  else if ABindingName = 'SubType' then
    Result := AItem.OpSubtype
  else if ABindingName = 'Amount' then
    Result := AItem.Amount
  else if ABindingName = 'AmountDecimal' then
    Result := TAccountComp.FormatMoneyDecimal(AItem.Amount)
  else if ABindingName = 'Fee' then
    Result := AItem.Fee
  else if ABindingName = 'FeeDecimal' then
    Result := TAccountComp.FormatMoneyDecimal(AItem.Fee)
  else if ABindingName = 'Balance' then
    Result := AItem.Balance
  else if ABindingName = 'BalanceDecimal' then
    Result := TAccountComp.FormatMoneyDecimal(AItem.Balance)
  else if ABindingName = 'Payload' then
    Result := AItem.PrintablePayload
  else if ABindingName = 'Description' then
    Result := AItem.OperationTxt
  else raise Exception.Create(Format('Field not found [%s]', [ABindingName]));
end;

{ TAccountsOperationsDataSource }

constructor TAccountsOperationsDataSource.Create(AOwner:TComponent);
begin
  inherited Create(AOwner);
  FAccounts := TSortedHashSet<Cardinal>.Create;
end;

destructor TAccountsOperationsDataSource.Destroy;
begin
 Inherited;
 FAccounts.Free;
end;

function TAccountsOperationsDataSource.GetAccounts : TArray<Cardinal> ;
begin
  Result := FAccounts.ToArray;
end;

procedure TAccountsOperationsDataSource.SetAccounts(const AAccounts : TArray<Cardinal>);
begin
  FAccounts.Clear;
  FAccounts.AddRange(AAccounts);
end;

procedure TAccountsOperationsDataSource.FetchAll(const AContainer : TList<TOperationResume>);
var
  block, i, keyIndex : integer;
  OPR : TOperationResume;
  accountBlockOps : TOperationsResumeList;
  node : TNode;
  list : Classes.TList;
  Op : TPCOperation;
  acc : Cardinal;
  GC : TDisposables;
begin
  if FAccounts.Count = 0
    then exit;
  node := TNode.Node;
  if Not Assigned(Node)
    then exit;
  TNode.Node.Bank.SafeBox.StartThreadSafe;
  try
    accountBlockOps := GC.AddObject(TOperationsResumeList.Create ) as TOperationsResumeList;
    list := GC.AddObject( Classes.TList.Create ) as Classes.TList;
    for acc in FAccounts do begin
      // Load pending operations first
      list.Clear;
      accountBlockOps.Clear;
      Node.Operations.OperationsHashTree.GetOperationsAffectingAccount( acc, list );
      if list.Count > 0 then
        for i := list.Count - 1 downto 0 do begin
          Op := node.Operations.OperationsHashTree.GetOperation( PtrInt( list[i] ) );
          If TPCOperation.OperationToOperationResume( 0, Op, false, acc, OPR ) then begin
            OPR.NOpInsideBlock := i;
            OPR.Block := Node.Operations.OperationBlock.block; ;
            OPR.Balance := Node.Operations.SafeBoxTransaction.Account( acc {Op.SignerAccount} ).balance;
            AContainer.Add(OPR);
          end;
      end;

      // Load block ops
      Node.GetStoredOperationsFromAccount(accountBlockOps, acc, MaxInt, 0, MaxInt);
      for i := 0 to accountBlockOps.Count - 1 do
        AContainer.Add(accountBlockOps[i]);
    end;
  finally
   TNode.Node.Bank.SafeBox.EndThreadSave;
  end;
end;

{ TPendingOperationsDataSource }

procedure TPendingOperationsDataSource.FetchAll(const AContainer : TList<TOperationResume>);
var
  i : integer;
  node : TNode;
  Op : TPCOperation;
  OPR : TOperationResume;
begin
 node := TNode.Node;
  if Not Assigned(Node) then exit;
  for i := Node.Operations.Count - 1 downto 0 do begin
    Op := Node.Operations.OperationsHashTree.GetOperation(i);
    If TPCOperation.OperationToOperationResume(0,Op, false, Op.SignerAccount,OPR) then begin
      OPR.NOpInsideBlock := i;
      OPR.Block := Node.Bank.BlocksCount;
      OPR.Balance := Node.Operations.SafeBoxTransaction.Account(Op.SignerAccount).balance;
      AContainer.Add(OPR);
    end;
  end;
end;

{ TOperationsDataSource }

procedure TOperationsDataSource.FetchAll(const AContainer : TList<TOperationResume>);
var
  block, i, j, keyIndex : integer;
  OPR : TOperationResume;
  blockOps : TPCOperationsComp;
  node : TNode;
  GC : TDisposables;

begin
  node := TNode.Node;
  if Not Assigned(Node) then exit;
  blockOps := GC.AddObject(TPCOperationsComp.Create(Nil)) as TPCOperationsComp;
  for block := FEnd downto FStart do begin  /// iterate blocks correctly
    opr := CT_TOperationResume_NUL;
    if (Node.Bank.Storage.LoadBlockChainBlock(blockOps, block)) then begin
      AContainer.Add( blockOps.GetMinerRewardPseudoOperation );
      if blockOps.Count = 0 then exit;
      for i := blockOps.Count - 1 downto 0 do begin    // reverse order
        if TPCOperation.OperationToOperationResume(block, blockOps.Operation[i], false, blockOps.Operation[i].SignerAccount, opr) then begin
          opr.NOpInsideBlock := i;
          opr.Block := block;
          opr.time := blockOps.OperationBlock.timestamp;
          AContainer.Add(opr);
        end;
      end;
    end else break;
  end;
end;

end.

