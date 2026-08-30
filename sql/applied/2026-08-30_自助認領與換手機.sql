/* ============================================================
   自助認領舊帳號 ＋ 自助換手機　　2026-08-30 · MIGI 咪吉麻將
   （文件表 E「自助認領」＋ 表 D 的 D2「set_member_phone_tx」）

   ── 🔴 動手前撈到的三件事（都不是原本知道的）────────
   ① **`members.phone_verified_at` 沒有任何函式會寫。**
      掃全庫 `pg_get_functiondef ilike '%phone_verified_at%'` → **0 支**。
      也就是註冊時客人**真的驗過簡訊，但沒有人在他身上蓋章** ——
      「這個帳號的手機驗過」這個概念在資料庫裡等於不存在。
      🔴 而整個自助認領的安全性**完全建立在那個章上面**。

   ② **註冊路徑根本沒有檢查驗證碼。**
      `line-login` 的 register 分支從頭到尾沒有呼叫
      `phone_recently_verified_tx` —— 前端有擋，後端沒有。
      🔴 也就是**跳過驗證那一步直接送出就會成功**。
      → 那一半在 Edge Function 修（同一批部署）。

   ③ `phone_otps.purpose` 的 CHECK 早就允許 `register / claim / change`
      —— 三條路當初就規劃好了，只是後兩條沒實作。

   ── 這份 SQL 建三支（全部只給 service_role）────────
   | 函式 | 做什麼 |
   |---|---|
   | `otp_consume_tx` | 把「這次驗證」用掉 ＋ 在會員身上蓋章 |
   | `claim_member_by_phone_tx` | 老客人用驗過的手機認回舊帳號 |
   | `set_member_phone_tx` | 客人自己換手機（一律要驗新號碼） |

   🔴 **三支都只有 service_role 能叫。** 它們每一支都會改「你是誰」
     或「怎麼找到你」—— 那是整個系統最貴的兩個欄位。
     前端一律經過 `line-login`（驗過 LINE 簽章）才碰得到。

   ── 🎯 自助認領的分級（這份 SQL 最重要的設計決定）──
   | 舊帳號的狀態 | 自助認領 | 為什麼 |
   |---|---|---|
   | 手機**驗過** | ✅ | 兩邊都證明過控制同一支號碼，那就是同一個身分 |
   | 未驗 ＋ **沒訂單也沒餘額** | ✅ | **沒有東西可以被偷**；認領只是為了解開「這支號碼已被占用」 |
   | 未驗 ＋ **有訂單或有餘額** | 🔴 店員 | 這一格就是 C4：A 把號碼填成 B 的，B 驗證成功就拿走 A 的點數 |
   | 已綁**別的** LINE | 🔴 店員 | 那是「換綁」不是「認領」，舊 LINE 可能還在別人手上 |
   | 這個 LINE **已經有別的會員** | 🔴 店員 | 那是**合併**（待辦 15），不是綁定 |

   🎯 **摩擦要跟風險等比例**，這是分級存在的唯一理由。
     一律開放 → C4 成立；一律關閉 → 這個功能等於沒做
     （而「未驗 ＋ 空帳號」正是櫃檯留過號碼的老客人最常見的樣子）。

   ⚠ **「未驗 ＋ 有價值」這一格會擋住五個測試帳號**，那是設計不是 bug。
     真實客人從上線第一天就會驗過，所以這一格之後只會出現在
     **櫃檯由店員手打號碼建立的帳號** 上 —— 而那正是打錯字風險最高、
     也最該由店員經手的那一類。**分級剛好落在對的地方。**

   ⚠ **不做「換綁自助化」**：`line_bound_elsewhere` 一律回店員。
     等官方帳號開了（待辦 38）能推播「有人要用你的號碼換綁」時，
     才有條件讓它自助 —— 現在沒有任何管道通知被踢掉的那個人。

   ── ⚠ 為什麼 `set_member_phone_tx` 不收 `p_member_id` ──
     會員是**從 `line_user_id` 查出來的**，不是參數。
     收 member_id 的話，這支函式就變成「給我一個 id 就改他的手機」——
     即使只有 service_role 叫得動，那個形狀本身就不該存在。
   ============================================================ */

-- ── ① 用掉這次驗證 ＋ 蓋章 ────────────────────────────
/* ⚠ 「用掉」與「蓋章」是**同一件事的兩半**，所以放在同一支：
     分開的話會出現「章蓋了但碼還能再用一次」或反過來，
     而那兩種都不會報錯。 */
create or replace function public.otp_consume_tx(
  p_org_id       uuid,
  p_phone        text,
  p_line_user_id text,
  p_purpose      text,
  p_member_id    uuid default null
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_phone text; v_id uuid;
begin
  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_invalid');
  end if;

  /* 條件跟 `phone_recently_verified_tx` 逐字一致 —— 驗過、沒用掉、15 分鐘內、
     而且**是同一個 LINE 驗的**（不然 A 驗過的碼 B 可以在 15 分鐘內拿去用）。 */
  select id into v_id from phone_otps
   where org_id = p_org_id and phone = v_phone and purpose = p_purpose
     and verified_at is not null and consumed_at is null
     and verified_at > now() - interval '15 minutes'
     and (p_line_user_id is null or line_user_id = p_line_user_id)
   order by verified_at desc limit 1;

  if v_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_verified');
  end if;

  update phone_otps set consumed_at = now() where id = v_id;

  /* 🔴 蓋章。沒有這一行，整套「驗過的帳號」就是空話。 */
  if p_member_id is not null then
    update members set phone_verified_at = now()
     where id = p_member_id and org_id = p_org_id and deleted_at is null;
  end if;

  return jsonb_build_object('ok', true, 'phone', v_phone);
end $$;


-- ── ② 自助認領舊帳號 ──────────────────────────────────
/* ── 🔴 `p_purpose` 為什麼要是參數（2026-08-30 使用者定的流程）──
   原本設計是第 2 步先問「這支號碼有人用嗎」，有人用才走認領。
   使用者指出那是**死路**：把「已被使用」做成紅字錯誤的話，
   **真正的號碼主人也被擋在門外**，自助救援永遠走不到入口。

   ✅ 正解更簡單：**不要先問。** 一律發驗證碼，
     驗過之後**由後端決定**這是註冊還是認領。
   ```
   輸入手機 → 驗證碼 → 驗過 ─┬─ 沒人用 → 繼續填生日性別
                              └─ 有人用 → 直接把舊帳號給你
   ```
   🎯 順帶把 `check_phone` 整支拿掉 —— 那本來是一個
     「輸入號碼就能問出是不是會員」的查詢器（有 LINE 就能一直問）。
     現在要知道任何事，**都得先證明你拿著那支手機**。

   ⇒ 所以註冊流程用的是 `purpose = 'register'` 的那組碼，
     `'claim'` 留給日後真的獨立出來的認領入口。**兩個都要能用。** */
create or replace function public.claim_member_by_phone_tx(
  p_org_id       uuid,
  p_phone        text,
  p_line_user_id text,
  p_purpose      text default 'register'
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_phone   text;
  v_t       members%rowtype;   -- 要認領的目標帳號
  v_mine    uuid;              -- 這個 LINE 現在綁著的會員（有的話）
  v_valued  boolean;
begin
  if p_org_id is null or coalesce(trim(p_line_user_id),'') = '' then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  if p_purpose not in ('register','claim') then
    return jsonb_build_object('ok', false, 'reason', 'bad_purpose');
  end if;

  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_invalid');
  end if;

  select * into v_t from members
   where org_id = p_org_id and phone = v_phone and deleted_at is null limit 1;

  /* 🔴 **「已經是你的」要排在驗證檢查之前，而且那不是洩漏。**
     它只認得出「這個帳號**已經綁在你自己的 LINE 上**」——
     而那件事 `whoami` 開機時早就告訴他了，問不出任何新東西。

     ⚠ 排在後面的話會出事：驗證碼**用過一次就消耗掉**，
       所以雙擊（或前端重送）的第二次會拿到 `not_verified`，
       客人看到的是「成功的那一次顯示失敗」。
       **冪等必須不依賴一個會被用掉的東西。** */
  if v_t.id is not null and v_t.line_user_id = p_line_user_id then
    return jsonb_build_object('ok', true, 'action', 'already_yours',
      'member_id', v_t.id, 'display_name', v_t.display_name);
  end if;

  /* 🔴 **再來才驗證。** 順序反過來的話，
     「這支號碼有沒有帳號」就變成一個不用驗證就問得到的查詢器。 */
  if not public.phone_recently_verified_tx(p_org_id, v_phone, p_line_user_id, p_purpose) then
    return jsonb_build_object('ok', false, 'reason', 'not_verified',
      'message', '請先完成手機驗證');
  end if;

  if v_t.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found',
      'message', '查不到用這支號碼的帳號');
  end if;

  -- 這個 LINE 已經有另一個會員 → 那是合併不是綁定（待辦 15）
  select id into v_mine from members
   where org_id = p_org_id and line_user_id = p_line_user_id and deleted_at is null limit 1;
  if v_mine is not null then
    return jsonb_build_object('ok', false, 'reason', 'merge_required',
      'message', '你的 LINE 已經有一個帳號了，兩個帳號要合併請洽櫃檯');
  end if;

  -- 目標已綁別的 LINE → 換綁，不自助
  if v_t.line_user_id is not null then
    return jsonb_build_object('ok', false, 'reason', 'line_bound_elsewhere',
      'message', '這支號碼的帳號已經綁了別的 LINE，請洽櫃檯協助');
  end if;

  /* 🔴 分級的那一格：未驗過的帳號**只有在沒有東西可以被偷時**才放行。
     ⚠ 判準用「有沒有付過錢／有沒有餘額」，不是「建立多久」——
       時間長短跟被偷走的價值無關。
     📌 `wallets` 每個會員一定有一列（`trg_members_wallet` AFTER INSERT
       自動建），所以查得到，新會員是 0。 */
  if v_t.phone_verified_at is null then
    v_valued :=
      exists (select 1 from orders o
               where o.member_id = v_t.id and o.status = 'paid' and o.deleted_at is null)
      or coalesce((select balance from wallets w where w.member_id = v_t.id), 0) > 0;
    if v_valued then
      return jsonb_build_object('ok', false, 'reason', 'staff_required',
        'message', '這個帳號有消費紀錄，為了保護你的權益請洽櫃檯由店員協助');
    end if;
  end if;

  update members set line_user_id = p_line_user_id where id = v_t.id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'update_failed');
  end if;

  -- 用掉驗證碼並蓋章（一次驗證只能認領一次）
  perform public.otp_consume_tx(p_org_id, v_phone, p_line_user_id, p_purpose, v_t.id);

  /* 稽核。⚠ `kind` 的 CHECK 只允許 care/birthday/winback/welcome/note，
     所以用 `note` ＋ `channel='system'`。
     🎯 放這張表而不是另建一張的理由：客人日後來櫃檯說
       「我的帳號怎麼變成別人的」，店員在會員查詢裡**看得到這一列**。
       稽核紀錄放在沒有人會打開的地方，等於沒有稽核。 */
  insert into member_interactions (org_id, member_id, channel, kind, note)
  values (p_org_id, v_t.id, 'system', 'note',
          '自助認領：以簡訊驗證 ' || left(v_phone,4) || '***' || right(v_phone,3) ||
          ' 綁定 LINE 帳號');

  select * into v_t from members where id = v_t.id;
  return jsonb_build_object('ok', true, 'action', 'claimed',
    'member_id', v_t.id, 'display_name', v_t.display_name);
end $$;


-- ── ③ 自助換手機 ──────────────────────────────────────
/* 對應文件表 D 的兩列，而**兩列走同一條路**：
   | 舊手機是空的 | ✅ 自己補 —— 你證明了控制新號碼 |
   | 舊手機有值   | ✅ 驗新號碼即可；驗不了（手機不在手上）才找店員 |
   🎯 舊號碼是什麼**根本不重要** —— 你證明的是「我控制這支新號碼」，
     那才是這個欄位存在的意義。 */
create or replace function public.set_member_phone_tx(
  p_org_id       uuid,
  p_line_user_id text,
  p_phone        text
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_phone text; v_m members%rowtype; v_old text;
begin
  if p_org_id is null or coalesce(trim(p_line_user_id),'') = '' then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_invalid',
      'message', '手機號碼格式不對');
  end if;

  -- 🔴 會員從 line_user_id 查出來，不由呼叫端指定
  select * into v_m from members
   where org_id = p_org_id and line_user_id = p_line_user_id and deleted_at is null limit 1;
  if v_m.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_registered');
  end if;

  /* 已經是這支號碼 → 冪等。⚠ 同上：**排在驗證之前**，
     否則雙擊的第二次會因為碼被用掉而顯示失敗。 */
  if v_m.phone = v_phone then
    return jsonb_build_object('ok', true, 'action', 'unchanged', 'phone', v_phone);
  end if;

  if not public.phone_recently_verified_tx(p_org_id, v_phone, p_line_user_id, 'change') then
    return jsonb_build_object('ok', false, 'reason', 'not_verified',
      'message', '請先完成手機驗證');
  end if;

  /* 🔴 新號碼被別人用了 → 擋。
     ⚠ 這裡**不可以**順手幫他認領那個帳號 —— 那是兩件事，
       而且那個帳號可能有別人的錢。要認領走 `claim_member_by_phone_tx`。 */
  if exists (select 1 from members
              where org_id = p_org_id and phone = v_phone
                and deleted_at is null and id <> v_m.id) then
    return jsonb_build_object('ok', false, 'reason', 'phone_taken',
      'message', '這支號碼已經是另一個 MIGI 帳號的了');
  end if;

  v_old := v_m.phone;

  update members set phone = v_phone where id = v_m.id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'update_failed');
  end if;

  perform public.otp_consume_tx(p_org_id, v_phone, p_line_user_id, 'change', v_m.id);

  insert into member_interactions (org_id, member_id, channel, kind, note)
  values (p_org_id, v_m.id, 'system', 'note',
          '自助換手機：' || coalesce(left(v_old,4) || '***' || right(v_old,3), '（原本沒有）') ||
          ' → ' || left(v_phone,4) || '***' || right(v_phone,3) || '（已通過簡訊驗證）');

  return jsonb_build_object('ok', true, 'action',
    case when v_old is null then 'added' else 'changed' end, 'phone', v_phone);
end $$;


-- ── ④ 權限：三支都只給 service_role ──────────────────
/* 🔴 硬規則 2.6 ＋ 2.6b：**兩個方向都要收**。
   · 舊函式的 anon 是從 `PUBLIC` 繼承的 → `revoke from public`
   · 新建的函式是 default privileges **明確**授權給 anon → `revoke from anon`
   只收一邊的話症狀跟沒收一模一樣，而且**不會報錯**。 */
revoke execute on function public.otp_consume_tx(uuid, text, text, text, uuid) from public;
revoke execute on function public.otp_consume_tx(uuid, text, text, text, uuid) from anon, authenticated;
grant  execute on function public.otp_consume_tx(uuid, text, text, text, uuid) to service_role;

revoke execute on function public.claim_member_by_phone_tx(uuid, text, text, text) from public;
revoke execute on function public.claim_member_by_phone_tx(uuid, text, text, text) from anon, authenticated;
grant  execute on function public.claim_member_by_phone_tx(uuid, text, text, text) to service_role;

revoke execute on function public.set_member_phone_tx(uuid, text, text) from public;
revoke execute on function public.set_member_phone_tx(uuid, text, text) from anon, authenticated;
grant  execute on function public.set_member_phone_tx(uuid, text, text) to service_role;


-- ── ⑤ 驗證（交易內造資料 → 測 → 回滾）────────────────
/* 🔴 **只驗「該擋的擋了」等於沒驗**（硬規則 3.55）——
   所以每一道擋牆都配一個「應該要通過」的正對照。
   ⚠ 造的資料全部回滾，一列都不會留下。

   🔴 **每個測試用不同的 LINE id，這不是龜毛。**
     第一版共用 `U_claimer`，而 ① 跑完之後那個 LINE 已經有帳號了
     ⇒ ② 會回 `merge_required` 而不是 `staff_required`，
     **測試通過但驗到的是別的東西**。
   🔴 **錢包不要自己插** —— `trg_members_wallet` AFTER INSERT
     已經幫每個新會員建好一列（第一版就是撞這個 pkey 炸的）。 */
do $$
declare
  v_org  uuid := '11111111-1111-1111-1111-111111111111';
  v_out  text := '';
  v_code text := '123456';
  a uuid; b uuid; c uuid; d uuid; e uuid; f uuid; g uuid; h uuid; j uuid;
  r  jsonb;
begin
  begin
    ---- 造帳號 ------------------------------------------------
    insert into members (org_id, display_name, phone) values (v_org,'測A','0900000901') returning id into a;
    insert into members (org_id, display_name, phone) values (v_org,'測B','0900000902') returning id into b;
    insert into members (org_id, display_name, phone, phone_verified_at)
      values (v_org,'測C','0900000903', now()) returning id into c;
    insert into members (org_id, display_name, phone, line_user_id)
      values (v_org,'測D','0900000904','U_someone_else') returning id into d;
    insert into members (org_id, display_name, phone) values (v_org,'測E','0900000905') returning id into e;
    insert into members (org_id, display_name, phone, line_user_id)
      values (v_org,'測F','0900000906','U_chg') returning id into f;
    insert into members (org_id, display_name, phone) values (v_org,'測G','0900000907') returning id into g;
    insert into members (org_id, display_name, phone) values (v_org,'測H','0900000909') returning id into h;
    insert into members (org_id, display_name, phone) values (v_org,'測J','0900000910') returning id into j;

    -- 錢包是觸發器建的，這裡只改金額（B 與 C 各有餘額 ＝ 有東西可以被偷）
    update wallets set balance = 100 where member_id in (b, c);

    ---- 造「已經驗過」的驗證碼 --------------------------------
    /* ⚠ 註冊流程用 `register`，個人設定改手機用 `change`。
       ③ 刻意用 `claim` —— 順便驗「兩種 purpose 都吃得到」。 */
    insert into phone_otps (org_id, phone, code_hash, purpose, line_user_id, expires_at, verified_at)
    select v_org, p, encode(extensions.digest(v_code || ':' || p, 'sha256'),'hex'),
           pu, lu, now() + interval '5 min', now()
      from (values
        ('0900000901','register','U_c1'),
        ('0900000902','register','U_c2'),
        ('0900000903','claim'   ,'U_c3'),
        ('0900000904','register','U_c4'),
        ('0900000909','register','U_c9'),   -- 綁在 U_c9，要用 U_cX 去試
        ('0900000910','register','U_c1'),   -- U_c1 認領完 A 之後再來一次 → 合併
        ('0900000908','change'  ,'U_chg'),  -- F 要換去的新號碼
        ('0900000907','change'  ,'U_chg')   -- 已被 G 占用的號碼
      ) as t(p, pu, lu);
    -- ⚠ 0900000905 刻意**不建**驗證碼 → 用來驗「沒驗過就想認領」

    ---- 測 · 認領 --------------------------------------------
    r := public.claim_member_by_phone_tx(v_org,'0900000901','U_c1');
    v_out := v_out || E'\n' || '① 空帳號自助認領（該通過）' || E'\t' ||
      case when r->>'action' = 'claimed' then '✅ claimed' else '🔴 ' || coalesce(r->>'reason','?') end;

    r := public.claim_member_by_phone_tx(v_org,'0900000902','U_c2');
    v_out := v_out || E'\n' || '② 未驗＋有餘額（該擋）' || E'\t' ||
      case when r->>'reason' = 'staff_required' then '✅ staff_required'
           else '🔴 ' || coalesce(r->>'action', r->>'reason','?') end;

    r := public.claim_member_by_phone_tx(v_org,'0900000903','U_c3','claim');
    v_out := v_out || E'\n' || '③ 驗過＋有餘額（該通過· 正對照）' || E'\t' ||
      case when r->>'action' = 'claimed' then '✅ claimed'
           else '🔴 ' || coalesce(r->>'reason','?') end;

    r := public.claim_member_by_phone_tx(v_org,'0900000904','U_c4');
    v_out := v_out || E'\n' || '④ 已綁別的 LINE（該擋）' || E'\t' ||
      case when r->>'reason' = 'line_bound_elsewhere' then '✅ line_bound_elsewhere'
           else '🔴 ' || coalesce(r->>'action', r->>'reason','?') end;

    r := public.claim_member_by_phone_tx(v_org,'0900000905','U_c5');
    v_out := v_out || E'\n' || '⑤ 沒驗過就認領（該擋）' || E'\t' ||
      case when r->>'reason' = 'not_verified' then '✅ not_verified'
           else '🔴 ' || coalesce(r->>'action', r->>'reason','?') end;

    r := public.claim_member_by_phone_tx(v_org,'0900000909','U_cX');
    v_out := v_out || E'\n' || '⑥ 別人驗的碼拿來用（該擋）' || E'\t' ||
      case when r->>'reason' = 'not_verified' then '✅ not_verified'
           else '🔴 ' || coalesce(r->>'action', r->>'reason','?') end;

    r := public.claim_member_by_phone_tx(v_org,'0900000910','U_c1');
    v_out := v_out || E'\n' || '⑦ 自己已經有帳號了（該擋）' || E'\t' ||
      case when r->>'reason' = 'merge_required' then '✅ merge_required'
           else '🔴 ' || coalesce(r->>'action', r->>'reason','?') end;

    /* 🔴 雙擊 —— 碼已經在 ① 用掉了。
       `already_yours` 排在驗證之前，所以這裡必須回成功。
       回 `not_verified` 的話，客人的第二次點擊會看到
       「成功的那一次顯示失敗」。 */
    r := public.claim_member_by_phone_tx(v_org,'0900000901','U_c1');
    v_out := v_out || E'\n' || '⑧ 重按一次（碼已用掉，該冪等）' || E'\t' ||
      case when r->>'action' = 'already_yours' then '✅ already_yours'
           else '🔴 ' || coalesce(r->>'reason','?') end;

    ---- 測 · 換手機 ------------------------------------------
    r := public.set_member_phone_tx(v_org,'U_chg','0900000908');
    v_out := v_out || E'\n' || '⑨ 換成沒人用的號碼（該通過）' || E'\t' ||
      case when r->>'action' = 'changed'
             and (select phone from members where id=f) = '0900000908'
             and (select phone_verified_at from members where id=f) is not null
           then '✅ changed ＋ 已蓋章'
           else '🔴 ' || coalesce(r->>'reason', r->>'action','?') end;

    r := public.set_member_phone_tx(v_org,'U_chg','0900000907');
    v_out := v_out || E'\n' || '⑩ 換成別人的號碼（該擋）' || E'\t' ||
      case when r->>'reason' = 'phone_taken' then '✅ phone_taken'
           else '🔴 ' || coalesce(r->>'action', r->>'reason','?') end;

    r := public.set_member_phone_tx(v_org,'U_chg','0900000908');
    v_out := v_out || E'\n' || '⑪ 換手機重按一次（該冪等）' || E'\t' ||
      case when r->>'action' = 'unchanged' then '✅ unchanged'
           else '🔴 ' || coalesce(r->>'reason','?') end;

    ---- 蓋章與消耗 -------------------------------------------
    v_out := v_out || E'\n' || '⑫ 認領後有沒有蓋章' || E'\t' ||
      case when (select phone_verified_at from members where id=a) is not null
           then '✅ phone_verified_at 有值' else '🔴 還是 null —— 蓋章沒生效' end;

    /* 該被用掉的剛好 3 組：① 認領 A、③ 認領 C、⑨ 換手機。
       被擋下的那幾次**一個字都不該寫**。 */
    v_out := v_out || E'\n' || '⑬ 用掉的驗證碼組數（該是 3）' || E'\t' ||
      (select case when count(*) = 3 then '✅ 3 組'
                   else '🔴 ' || count(*) || ' 組 —— 擋下的那幾次也動到資料了' end
         from phone_otps where consumed_at is not null and org_id = v_org
          and phone like '09000009%');

    v_out := v_out || E'\n' || '⑭ 稽核有沒有留（該是 3 列）' || E'\t' ||
      (select case when count(*) = 3 then '✅ 3 列'
                   else '🔴 ' || count(*) || ' 列' end
         from member_interactions
        where member_id in (a,c,f) and channel = 'system' and kind = 'note');

    ---- 驗權限 -----------------------------------------------
    /* 🔴 硬規則 2.6b：**同時看「明確授權」與「PUBLIC 繼承」**。
       `has_function_privilege` 分不出這兩種，只用它會在收錯方向時
       看到跟沒收一模一樣的畫面。 */
    v_out := v_out || E'\n' || '⑮ anon 叫不叫得動這三支' || E'\t' ||
      (select case when count(*) = 0 then '✅ 三支都收乾淨了'
                   else '🔴 還有 ' || count(*) || ' 支 anon 進得來' end
         from pg_proc p
        where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
          and p.proname in ('otp_consume_tx','claim_member_by_phone_tx','set_member_phone_tx')
          and (
            exists (select 1 from aclexplode(p.proacl) x
                     where x.grantee = 'anon'::regrole::oid and x.privilege_type='EXECUTE')
            or p.proacl is null
            or exists (select 1 from aclexplode(p.proacl) x
                        where x.grantee = 0 and x.privilege_type='EXECUTE')
          ));

    raise exception 'migi_rollback';
  exception when others then
    /* ⚠ 硬規則 3.9：訊息一定要設在 exception 處理器裡 ——
       設在成功路徑上再 raise 的話，`is_local = true` 會跟著被回滾，最後印出空白。 */
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.claim_test', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.claim_test', true), E'\n')) as x
 where coalesce(x,'') <> '';
