/* ============================================================
   會員等級可在後台編輯（待辦 0.6 · 2026-09-08）

   ── 為什麼是今天做 ────────────────────────────────────
   `member_tiers` 是主檔，`checkout_tx` 與 `pos_member_detail_tx` 都**即時查它**
   ⇒ 改一個數字**立刻生效不用部署**。但 migi-admin 沒有畫面，
   所以到今天為止改折扣**只能跑 SQL**。

   🔴 **而今天剛好證明了它的代價**：
   ```
   CLAUDE.md 記      升等門檻「暫定 0 / 10,000 / 50,000」
   線上實際           0 / 6,000 / 20,000
   而那個錯誤生了第二個：《首店周邊商品規劃》拿它算杯子回本，
   還把「金額門檻」寫成「月來店 8 次」
   ```
   ⇒ **值看不見，所以文件漂了，而漂掉的值被拿去做商業決策。**
     一頁四列就根治它 —— 這不是「方便」，是**讓事實有一個看得到的家**。

   ── 🔴 `member_tiers` 沒有稽核欄位，這一份補上 ──────────
   欄位只有 `code / label / discount_pct / threshold_amount / sort /
   is_active / note / created_at` —— **沒有 `updated_at` 也沒有 `updated_by`**。
   而這張表裝的是**折扣率**。同今天早上 `products` 那個病
   （9 筆商品 `updated_by` 全是 null），而且**不可回溯**：
   今天不填，「這個折扣是誰改的」這段歷史就永遠沒有（硬規則 5.6）。

   ── 擋牆：三道，全部是查出來的不是想出來的 ────────────
   撈 `recalc_member_tier_tx` 才知道它怎麼選等級：
   ```sql
   select code from member_tiers
    where is_active and threshold_amount is not null and threshold_amount <= v_spent
    order by sort desc limit 1;        -- 「達標的最高一階」
   ```
   ⇒ ① **`sort` 與 `threshold_amount` 必須同向遞增**。
      把提拉米蘇改成 3,000（低於焦糖布丁 6,000）的話，
      花 4,000 的人會**直接跳到 9 折並跳過焦糖布丁** ——
      不報錯，只是升等規則靜悄悄變了。
   ⇒ ② **還有會員在用的等級不可以停用**。
      `members.tier` 的欄位預設值是**寫死的 `'bubble_tea'`**，
      停用它會讓每個新會員指向一個停用的階。
      ⚠ 用「有沒有人在用」判斷，**不要寫死 `bubble_tea`** ——
        寫死的話日後改預設等級又要改這裡（同一個概念兩份定義）。
   ⇒ ③ `discount_pct` 0..100（DB 已有 CHECK，這裡是為了回**人話**
      而不是讓 23514 冒到畫面上）。

   ⚠ **`code` 不可編輯** —— 它是 PK，而且被寫進判斷邏輯與歷史訂單快照
     （`orders.tier_discount_pct` 是當時的快照，但 `members.tier` 存的是 code）。
     中文名（`label`）才是可以改的那一層。

   ⚠ **`sort` 也不開放編輯** —— 它決定「誰比誰高」，而那是**制度設計**
     不是營運參數。真的要調整順序時值得專門討論一次，不該在一個
     輸入框裡順手改掉。

   ── 存的是折抵幅度，畫面顯示折數（兩層刻意分開）────────
   `discount_pct = 20` 是**折抵 20%**（＝8 折）。
   遷就顯示去存 80 就會長出 `coupons.discount_value` 那種矛盾
   （那一欄是「折抵百分比」而不是折數，9 折券要填 10）。
   ⇒ **資料層不動，換算放前端。**
   ============================================================ */

-- ══════════════════════════════════════════════════════
-- ① 稽核欄位（這張表原本沒有）
-- ══════════════════════════════════════════════════════
alter table public.member_tiers
  add column if not exists updated_at timestamptz,
  add column if not exists updated_by uuid;

comment on column public.member_tiers.updated_by is
  '最後改動者的 staff_id（2026-09-08 新增）。⚠ 由 admin_update_member_tier_tx 從 current_staff() 寫入，不收參數 —— 收參數的話登入的人可以填別人的 id，而那比沒有稽核更糟。';

-- ══════════════════════════════════════════════════════
-- ② 後台清單（含停用的、含「有幾個會員在用」）
-- ══════════════════════════════════════════════════════
create or replace function public.admin_list_member_tiers_tx()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
begin
  if not public.can('tier.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
                              'message', '沒有權限查看會員等級');
  end if;

  /* ⚠ **不是 `list_member_tiers_tx`** —— 那一支濾掉停用的、也不回
     `is_active` 與 `sort`（POS 與會員 App 在讀它，不可以改）。 */
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'code', t.code,
             'label', t.label,
             'discount_pct', t.discount_pct,
             'threshold_amount', t.threshold_amount,
             'sort', t.sort,
             'is_active', t.is_active,
             'note', t.note,
             'updated_at', t.updated_at,
             /* 🎯 **有幾個人在這一階** —— 讓改動的後果看得見
                （「改這一階會影響 3 個人」），而不是改完才知道。
                ⚠ 也是 ② 那道擋牆的依據。 */
             'members', (select count(*) from members m
                          where m.tier = t.code and m.deleted_at is null)
           ) order by t.sort, t.code)
      from member_tiers t), '[]'::jsonb));
end $fn$;

-- ══════════════════════════════════════════════════════
-- ③ 更新一階
-- ══════════════════════════════════════════════════════
create or replace function public.admin_update_member_tier_tx(
  p_code             text,
  p_label            text,
  p_discount_pct     integer,
  p_threshold_amount bigint,     -- null = 邀請制（不靠累積取得）
  p_is_active        boolean
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_staff uuid;
  v_label text := nullif(btrim(coalesce(p_label, '')), '');
  v_sort  int;
  v_using int;
  v_bad   text;
begin
  if not public.can('tier.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
                              'message', '沒有權限編輯會員等級');
  end if;
  v_staff := (select staff_id from public.current_staff());

  select sort into v_sort from member_tiers where code = p_code;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個等級');
  end if;

  if v_label is null then
    return jsonb_build_object('ok', false, 'reason', 'label_required', 'message', '請填等級名稱');
  end if;
  /* ③ DB 已有 CHECK，這裡是為了回人話而不是讓 23514 冒到畫面上。 */
  if p_discount_pct is null or p_discount_pct < 0 or p_discount_pct > 100 then
    return jsonb_build_object('ok', false, 'reason', 'bad_pct',
                              'message', '折抵幅度必須在 0 到 100 之間');
  end if;
  if p_threshold_amount is not null and p_threshold_amount < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_threshold',
                              'message', '升等門檻不可以是負的');
  end if;

  /* ── ② 還有會員在用的等級不可以停用 ──────────────────
     `members.tier` 的欄位預設值是寫死的 `'bubble_tea'`，
     而 `checkout_tx` 查主檔拿折扣 —— 停用之後那些人的折扣會落空。
     ⚠ 用「有沒有人在用」判斷，不寫死 code。 */
  if p_is_active = false then
    select count(*) into v_using from members
     where tier = p_code and deleted_at is null;
    if v_using > 0 then
      return jsonb_build_object('ok', false, 'reason', 'tier_in_use',
        'message', '還有 ' || v_using || ' 位會員在這一階，不能停用');
    end if;
  end if;

  /* ── ① 門檻必須隨 sort 遞增 ────────────────────────────
     🔴 `recalc_member_tier_tx` 選的是「達標的**最高一階**」（`order by sort desc`）。
       門檻與 sort 反向的話，花得少的人會跳到更高的階 ——
       **不報錯，只是升等規則靜悄悄變了**。
     ⚠ `threshold_amount is null` 是邀請制（主廚特調），不參與比較。
     ⚠ 比較的是**改完之後**的樣子，所以用即將寫入的值去比。 */
  if p_threshold_amount is not null and p_is_active then
    select string_agg(t.label || '（' || t.threshold_amount || '）', '、' order by t.sort)
      into v_bad
      from member_tiers t
     where t.code <> p_code and t.is_active and t.threshold_amount is not null
       and ((t.sort < v_sort and t.threshold_amount > p_threshold_amount)
         or (t.sort > v_sort and t.threshold_amount < p_threshold_amount));
    if v_bad is not null then
      return jsonb_build_object('ok', false, 'reason', 'threshold_out_of_order',
        'message', '門檻必須由低階到高階遞增，這個值與「' || v_bad || '」衝突');
    end if;
  end if;

  update member_tiers
     set label = v_label,
         discount_pct = p_discount_pct,
         threshold_amount = p_threshold_amount,
         is_active = coalesce(p_is_active, true),
         updated_at = now(),
         updated_by = v_staff          -- 🔴 從 current_staff() 取，不收參數
   where code = p_code;

  return jsonb_build_object('ok', true, 'code', p_code);
end $fn$;


/* ── 授權（硬規則 2.6b：兩個方向都要收）──────────────────── */
revoke execute on function public.admin_list_member_tiers_tx()                              from public;
revoke execute on function public.admin_update_member_tier_tx(text,text,integer,bigint,boolean) from public;
revoke execute on function public.admin_list_member_tiers_tx()                              from anon;
revoke execute on function public.admin_update_member_tier_tx(text,text,integer,bigint,boolean) from anon;
grant  execute on function public.admin_list_member_tiers_tx()                              to authenticated;
grant  execute on function public.admin_update_member_tier_tx(text,text,integer,bigint,boolean) to authenticated;


/* ============================================================
   驗證（單一 SELECT）
   ⚠ 硬規則 3.55：每一道擋牆都要有正對照 ——
     只驗「擋住了」的話，一支永遠回錯的實作也會全綠。
   ⚠ 寫入測試包在子交易裡 raise 回滾，**一列都不會真的留下**。
   ============================================================ */
do $$
declare
  v_uid uuid; v_msg text := ''; v_r jsonb; v_code text; v_free text;
begin
  select s.auth_uid into v_uid from staff s
   where s.auth_uid is not null and s.deleted_at is null
     and s.role in ('hq','owner') limit 1;
  if v_uid is null then
    perform set_config('migi.p', '🔴 找不到總部 staff', true); return;
  end if;

  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);
    set local role authenticated;

    -- ① 正對照：讀得到，而且**含停用的與人數**
    v_r := public.admin_list_member_tiers_tx();
    v_msg := case when (v_r ->> 'ok')::boolean and jsonb_array_length(v_r -> 'rows') >= 4
      then '✅ ① 讀到 ' || jsonb_array_length(v_r -> 'rows') || ' 階：' ||
           (select string_agg((e ->> 'label') || ' ' || (e ->> 'discount_pct') || '%／門檻' ||
                              coalesce(e ->> 'threshold_amount', '邀請制') ||
                              '／' || (e ->> 'members') || ' 人', '、')
              from jsonb_array_elements(v_r -> 'rows') e)
      else '🔴 ① ' || left(v_r::text, 150) end;

    -- ② 正對照：改名字要真的改得動
    v_code := v_r -> 'rows' -> 1 ->> 'code';
    v_r := public.admin_update_member_tier_tx(v_code, '改名測試',
             (v_r -> 'rows' -> 1 ->> 'discount_pct')::int,
             (v_r -> 'rows' -> 1 ->> 'threshold_amount')::bigint, true);
    v_msg := v_msg || E'\n' || case when (v_r ->> 'ok')::boolean
      then '✅ ② 改得動（' || v_code || '）' else '🔴 ② ' || v_r::text end;

    -- ③ 稽核欄位真的寫進去了（這一份存在的主因之一）
    v_msg := v_msg || E'\n' || (
      select case when updated_by is not null and updated_at is not null
        then '✅ ③ updated_by/at 有值（在此之前這張表沒有這兩欄）'
        else '🔴 ③ 稽核沒接上' end from member_tiers where code = v_code);

    -- ④ 🔴 負對照：門檻反向要被擋
    v_r := public.admin_update_member_tier_tx('tiramisu', '提拉米蘇', 10, 100, true);
    v_msg := v_msg || E'\n' || case when (v_r ->> 'reason') = 'threshold_out_of_order'
      then '✅ ④ 門檻反向被擋：' || (v_r ->> 'message')
      else '🔴 ④ 竟然放行：' || left(v_r::text, 150) end;

    -- ⑤ 🔴 負對照：還有人在用的等級不可停用
    select code into v_code from member_tiers t
     where exists (select 1 from members m where m.tier = t.code and m.deleted_at is null)
     limit 1;
    if v_code is null then
      v_msg := v_msg || E'\n⚪ ⑤ 沒有任何等級有會員，這一格測不了';
    else
      v_r := public.admin_update_member_tier_tx(v_code, '測試', 0, 0, false);
      v_msg := v_msg || E'\n' || case when (v_r ->> 'reason') = 'tier_in_use'
        then '✅ ⑤ 有人在用不可停用：' || (v_r ->> 'message')
        else '🔴 ⑤ 竟然放行：' || left(v_r::text, 150) end;
    end if;

    -- ⑥ 正對照：**沒有人在用**的等級可以停用（少了這格，一支永遠拒絕的實作也會全綠）
    select code into v_free from member_tiers t
     where not exists (select 1 from members m where m.tier = t.code and m.deleted_at is null)
     limit 1;
    if v_free is null then
      v_msg := v_msg || E'\n⚪ ⑥ 每一階都有人，停用的正對照測不了';
    else
      v_r := public.admin_update_member_tier_tx(v_free, '測試', 0, null, false);
      v_msg := v_msg || E'\n' || case when (v_r ->> 'ok')::boolean
        then '✅ ⑥ 沒人用的可以停用（' || v_free || '）—— 沒有過度阻擋'
        else '🔴 ⑥ 被誤擋：' || left(v_r::text, 150) end;
    end if;

    -- ⑦ 負對照：折抵幅度超出範圍要回人話不是 23514
    v_r := public.admin_update_member_tier_tx('bubble_tea', '珍珠奶茶', 150, 0, true);
    v_msg := v_msg || E'\n' || case when (v_r ->> 'reason') = 'bad_pct'
      then '✅ ⑦ 折抵幅度超範圍 → 人話' else '🔴 ⑦ ' || left(v_r::text, 120) end;

    -- ⑧ 負對照：非總部一律 forbidden
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
    v_msg := v_msg || E'\n' || case
      when (public.admin_list_member_tiers_tx() ->> 'reason') = 'forbidden'
      then '✅ ⑧ 非總部被擋' else '🔴 ⑧ 竟然讀得到' end;

    reset role;
    raise exception 'migi_rollback';
  exception when others then
    begin reset role; exception when others then null; end;
    if sqlerrm <> 'migi_rollback' then v_msg := v_msg || E'\n🔴 中途拋錯：' || sqlerrm; end if;
    perform set_config('migi.p', v_msg, true);
  end;
end $$;

select
  '① 欄位：' ||
    (select string_agg(column_name, ' ' order by column_name)
       from information_schema.columns
      where table_schema='public' and table_name='member_tiers'
        and column_name in ('updated_at','updated_by'))
    || '（應為 updated_at updated_by）'                                      as "①稽核欄位",
  '② 函式 ' || (select count(*)::text from pg_proc
     where pronamespace='public'::regnamespace
       and proname in ('admin_list_member_tiers_tx','admin_update_member_tier_tx'))
    || ' / 2'                                                                as "②建立",
  (select string_agg(p.proname || '〔auth=' ||
            case when exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE')
                 then '✅' else '🔴' end ||
            ' anon=' ||
            case when exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
                 then '🔴有' else '✅無' end ||
            ' PUBLIC=' ||
            case when p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee=0 and a.privilege_type='EXECUTE')
                 then '🔴有' else '✅無' end || '〕', E'\n')
     from pg_proc p where p.pronamespace='public'::regnamespace
       and p.proname like 'admin_%member_tier%')                             as "③授權",
  /* ⚠ 正對照：`list_member_tiers_tx`（POS 與會員 App 在讀的那一支）**不可以被改到** */
  case when (select count(*) from pg_proc
               where pronamespace='public'::regnamespace and proname='list_member_tiers_tx') = 1
       then '✅ ④ POS 那支還在（沒被改到）' else '🔴 ④ POS 那支不見了' end   as "④沒動到POS那支",
  coalesce(nullif(current_setting('migi.p', true), ''), '🔴 沒有測試訊息')    as "⑤～⑫行為";
