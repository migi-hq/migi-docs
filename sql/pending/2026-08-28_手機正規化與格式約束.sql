/* ============================================================
   手機正規化：讓「同一支手機」永遠只有一種寫法
   2026-08-28

   ── 🔴 這不是體驗問題，是防重複帳號的必要條件 ────────
   `uq_members_phone (org_id, phone)` 是**字串比對**：

       註冊時填      0912345678
       換 LINE 時填  0912-345-678

   **是兩個不同的值 → 唯一索引不會擋 → 建出兩個帳號。**

   而手機是**唯一能認出「這個人以前來過」的東西**
   （`register_member_tx` 的 rebound 路徑）。
   橋的兩端格式不同，橋就接不起來 —— 而那正是待辦 15
   （帳號合併，「越晚越貴」）要防的事。

   ⚠ 現有 4 筆剛好都是 `09xxxxxxxx`，**那是運氣不是設計**：
     `members.phone` 沒有任何格式約束，`register_member_tx` 也只做了 trim。

   ── 為什麼正規化要在後端 ────────────────────────────
   前端做的話，POS 與會員 App 兩邊可能不一致 ——
   而「兩邊都有一份、靠人維護一致」正是這個專案一再踩的坑
   （折扣率、贈點、券的計算都踩過）。

   ── 照既有的模式做，不要發明新的 ────────────────────
   `migi_norm_nickname(p text)` ＋ `members_display_name_chk`
   已經是這一套（正規化函式 ＋ CHECK 約束）。這裡照抄。

   ── 規則 ────────────────────────────────────────────
   · 去掉所有非數字字元（空白、-、()、全形）
   · `+886 9xxxxxxxx` / `886 9xxxxxxxx` → `09xxxxxxxx`
   · 結果必須符合 `^09\d{8}$`，否則視為無效
   ⚠ **只接受台灣手機**。市話不收 —— 這個欄位的用途是身分綁定，
     而市話會共用（一家人、一間公司），無法識別個人。
   ⚠ 外籍客人的號碼日後要支援時，改的是 `migi_norm_phone` 一支函式
     與那條 CHECK，不用動任何呼叫端。
   ============================================================ */

-- ── 一、正規化函式 ──────────────────────────────────
create or replace function public.migi_norm_phone(p text)
returns text
language sql
immutable
as $function$
  select case
    when p is null then null
    else (
      with digits as (
        -- 去掉所有非數字（含全形、空白、-、()、+）
        select regexp_replace(p, '[^0-9]', '', 'g') as d
      )
      select case
        -- 886 開頭（國際碼）→ 補回 0
        when d ~ '^8869[0-9]{8}$' then '0' || substring(d from 4)
        when d ~ '^09[0-9]{8}$'   then d
        else null          -- 不合格式一律回 null，讓呼叫端自己決定怎麼處理
      end from digits
    )
  end
$function$;

comment on function public.migi_norm_phone(text) is
  '台灣手機正規化：去掉非數字、+886 轉 0，結果必須是 09xxxxxxxx，否則回 null。
   🔴 存在的理由是 uq_members_phone 是字串比對 —— 格式不一致會讓同一個人建出兩個帳號。';

-- ── 二、CHECK：資料庫層保證只有一種寫法 ──────────────
-- ⚠ 現有 4 筆都是 09xxxxxxxx，所以可以直接加 VALID（不用 NOT VALID）。
alter table public.members
  drop constraint if exists members_phone_chk;

alter table public.members
  add constraint members_phone_chk
  check (phone is null or phone = public.migi_norm_phone(phone));

/* ── 三、register_member_tx 正規化後再查、再寫 ─────────
   🔴 **查詢也要用正規化後的值** —— 只在寫入時正規化的話，
     「用 0912-345-678 來找 0912345678」還是找不到，rebound 照樣走不到。
   ⚠ 用「撈線上定義 → 字串取代 → execute」而不是手抄整支
     （同今天改 p_rounds 預設值那次的理由）。 */
do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname='register_member_tx' limit 1;
  if v_def is null then raise exception '🔴 找不到 register_member_tx'; end if;

  if v_def ilike '%migi_norm_phone%' then
    raise notice 'register_member_tx 已經有正規化，略過';
    return;
  end if;

  /* 在「need phone or line_user_id」那道檢查**之前**插入正規化。
     那一段是已知的錨點（2026-08-26 版本）。 */
  v_new := replace(v_def,
    '  if coalesce(trim(p_phone),'''') = '''' and coalesce(trim(p_line_user_id),'''') = '''' then',
    '  /* ★ 2026-08-28：手機一律正規化後再用。
       🔴 uq_members_phone 是字串比對 —— 0912-345-678 與 0912345678
         會被當成兩個人，rebound 路徑就永遠走不到。
       ⚠ 查詢與寫入都要用正規化後的值，只做其中一邊等於沒做。 */
    if coalesce(trim(p_phone),'''') <> '''' then
      p_phone := public.migi_norm_phone(p_phone);
      if p_phone is null then
        raise exception ''phone_invalid'';
      end if;
    end if;

  if coalesce(trim(p_phone),'''') = '''' and coalesce(trim(p_line_user_id),'''') = '''' then');

  if v_new = v_def then
    raise exception '🔴 找不到預期的錨點片段 —— 函式內容與預期不同，整支回滾';
  end if;
  if v_new not like '%migi_norm_phone%' then
    raise exception '🔴 取代後仍然沒有 migi_norm_phone —— 整支回滾';
  end if;
  execute v_new;
end $$;

/* ============================================================
   實測（交易內，最後回滾）

   ⚠ 硬規則 3.55：驗「該擋的擋了」**也要驗「該過的過了」**。
     只驗「亂填被擋」的話，把全部都擋掉也會通過那個測試。
   ============================================================ */
do $$
declare v_msg text := ''; r record;
begin
  -- ① 正規化函式本身
  for r in
    select * from (values
      ('0912345678',    '0912345678', '標準'),
      ('0912-345-678',  '0912345678', '有分隔號'),
      ('0912 345 678',  '0912345678', '有空白'),
      ('(0912)345678',  '0912345678', '有括號'),
      ('+886912345678', '0912345678', '國際碼'),
      ('886912345678',  '0912345678', '國際碼無加號'),
      ('0212345678',    null,         '市話→擋'),
      ('091234567',     null,         '少一碼→擋'),
      ('09123456789',   null,         '多一碼→擋'),
      ('abcdefghij',    null,         '亂填→擋')
    ) t(inp, want, note)
  loop
    v_msg := v_msg || r.note || '　' || r.inp || ' → ' ||
             coalesce(public.migi_norm_phone(r.inp), 'null') ||
             case when public.migi_norm_phone(r.inp) is not distinct from r.want
                  then '　✅' else '　🔴 應為 ' || coalesce(r.want,'null') end || E'\n';
  end loop;

  perform set_config('migi.ph', v_msg, true);
end $$;

do $$
declare
  v_org uuid; v_res jsonb; v_msg text; v_phone text;
begin
  select org_id into v_org from members where deleted_at is null limit 1;
  select phone into v_phone from members where deleted_at is null and phone is not null limit 1;
  if v_org is null or v_phone is null then
    perform set_config('migi.ph2', '⚠ 跳過：沒有會員或沒有手機', true);
    return;
  end if;

  begin
    /* ② 🎯 最重要的一個：用「有分隔號」的寫法去找既有會員，
       應該要找得到（existing_phone），而不是建出第二個帳號。 */
    v_res := register_member_tx(v_org, '測試用暱稱',
               substring(v_phone from 1 for 4) || '-' ||
               substring(v_phone from 5 for 3) || '-' ||
               substring(v_phone from 8));
    v_msg := '② 用「' || substring(v_phone from 1 for 4) || '-…」找既有會員　回傳=' ||
             coalesce(v_res->>'action','null') ||
             case when (v_res->>'action') in ('existing_phone','rebound','existing_line')
                  then '　✅ 找到了，沒有建第二個'
                  else '🔴 竟然是 ' || coalesce(v_res->>'action','null') || ' —— 建出重複帳號了' end;

    -- ③ 亂填的手機要被擋
    begin
      v_res := register_member_tx(v_org, '測試用暱稱2', '0212345678');
      v_msg := v_msg || E'\n\n③ 市話 0212345678　🔴 沒被擋，回傳=' || coalesce(v_res->>'action','null');
    exception when others then
      v_msg := v_msg || E'\n\n③ 市話 0212345678　→ ' || sqlerrm ||
               case when sqlerrm like '%phone_invalid%' then '　✅ 擋下' else '　🟡 擋了但訊息不是預期的' end;
    end;

    raise exception 'rollback_on_purpose';
  exception
    when others then
      if sqlerrm = 'rollback_on_purpose' then
        perform set_config('migi.ph2', v_msg, true);
      else
        perform set_config('migi.ph2',
          coalesce(nullif(v_msg,''),'') || E'\n🔴 測試拋錯：' || sqlerrm, true);
      end if;
  end;
end $$;

/* 驗證（單一 SELECT） */
select 序, 項目, 內容 from (

  select 1 as 序, '① migi_norm_phone 逐項測試' as 項目,
         coalesce(current_setting('migi.ph', true), '🔴 沒執行') as 內容

  union all
  select 2, '② register_member_tx 實測（找得到 vs 擋下）',
         coalesce(current_setting('migi.ph2', true), '🔴 沒執行')

  union all
  select 3, '③ members_phone_chk 約束',
         coalesce((select pg_get_constraintdef(c.oid)
                     from pg_constraint c join pg_class t on t.oid=c.conrelid
                    where t.relnamespace='public'::regnamespace and t.relname='members'
                      and c.conname='members_phone_chk'), '🔴 沒建成功')

  union all
  select 4, '④ register_member_tx 是否已正規化',
         case when (select pg_get_functiondef(p.oid) from pg_proc p
                     where p.pronamespace='public'::regnamespace and p.prokind='f'
                       and p.proname='register_member_tx' limit 1) ilike '%migi_norm_phone%'
              then '✅ 有' else '🔴 沒有' end

  union all
  select 5, '⑤ 既有會員的手機（確認沒被動到）',
         (select string_agg(display_name || '：' || coalesce(phone,'無'), '　' order by display_name)
            from members where deleted_at is null)

) x order by 序;
