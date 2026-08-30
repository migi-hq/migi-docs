/* ============================================================
   🔴 堵 A3：手機對得上不再自動把 LINE 綁進舊帳號
   2026-08-30

   🚧 **部署順序：前端要先上。**
   `migi-web` commit 35856e2 把判準從「action 名稱」改成
   「後端有沒有給 member_id」。反了的話，在前端部署完成前
   踩到這條路的客人會拿到 `member_id = undefined` 而卡在壞掉的畫面。
   ⚠ 那一版單獨部署是安全的（後端還不會送 `phone_taken`）。

   ── 改什麼 ──────────────────────────────────────────
   ```
   改前：手機對得上 ＋ 對方還沒綁 LINE → 直接綁上去 → 'rebound'
   改後：手機對得上 ＋ 對方還沒綁 LINE → 'phone_taken'，一個字都不寫
   ```

   ── 為什麼（見 docs/03-會員App與社交/身分綁定的所有情境與處理.md 表 A）──
   ```sql
   update members set line_user_id = p_line_user_id
    where id = v_existing and line_user_id is null;   -- v_existing = 手機對得上的那個人
   ```
   填一個**還沒綁 LINE 的舊客人的手機** → 你的 LINE 綁進他的帳號
   → 錢包、消費紀錄、等級、優惠券全部到手。
   ⚠ 唯一的護欄是 `line_user_id is null`，所以**暴露的正是
     「櫃檯註冊過但還沒用 LINE 的舊客人」** —— 而那群人正是有餘額的人。

   🎯 **今天堵零代價**：只有 4 個測試帳號 ＋ 創辦人，而創辦人已經綁好了。
     上線後才堵，影響的是每一個櫃檯註冊過的舊客人。

   ── 保留下來的一條路 ────────────────────────────────
   ⚠ `v_cur_line = p_line_user_id`（同一個人重試或併發）仍然回 `existing_line`
     並給 member_id —— **那是他自己的帳號**，不是洩漏。
     🔴 這條不能砍：LIFF 在網路不穩時重送很常見，砍掉會讓
       「已經綁好的人再按一次」變成「請洽櫃檯」。

   ── 舊客人怎麼綁回來 ────────────────────────────────
   ⏳ 兩條路都還沒做（見那份文件的表 E）：
     ① 簡訊 OTP —— 自助，但每則要錢
     ② 店員綁定 —— 一次性工程，但**卡待辦 20（店員登入）**，
       而且需要一個綁定碼機制（POS 拿不到客人的 `line_user_id`）
   ⚠ 在那之前，四個測試帳號要接 LINE 就從 Dashboard 直接下
     `rebind_line_user_tx`（service_role），不受這份影響。

   ── 簽名沒變 ⇒ CREATE OR REPLACE ────────────────────
   ⚠ 從 `pg_get_functiondef` 撈線上版做定點取代（硬規則 3）。
     這支很長，手打全文抄錯的風險比較大。
   ============================================================ */

do $$
declare v_old text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_old from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname='register_member_tx';
  if v_old is null then raise exception '找不到 register_member_tx'; end if;

  /* 先確認上一份（停止洩漏 member_id）真的跑過了 ——
     🔴 沒跑過就套這一份的話，`phone_taken` 會擋住 A3，
       但 A4／A5 仍然在交出別人的 member_id，而驗證段不會發現。 */
  if v_old !~ 'v_action = ''existing_phone''' then
    raise exception '請先執行 applied/2026-08-30_註冊路徑停止洩漏會員身分.sql';
  end if;

  /* 把「更新 → 看 FOUND」整段換成「先查 → 不是他就拒絕」。
     ⚠ 順序反過來是重點：原版是**先寫再判斷**，
       所以「不該綁」那一刻資料已經寫進去了。 */
  v_new := regexp_replace(v_old,
    'update members\s*\n?\s*set line_user_id = p_line_user_id, updated_at = now\(\)\s*\n?\s*where id = v_existing and line_user_id is null;',
    'select line_user_id into v_cur_line from members where id = v_existing;',
    'g');
  if v_new = v_old then raise exception '錨點①（那段 update）沒對上'; end if;

  v_old := v_new;
  /* `if not found then ... else v_action := 'rebound'; end if;` 整段換掉 */
  v_new := regexp_replace(v_old,
    'if not found then.*?v_action := ''rebound'';\s*end if;',
    'if v_cur_line = p_line_user_id then' ||
    E'\n          v_action := ''existing_line'';   -- 同一個人重試／併發，是他自己的帳號' ||
    E'\n        else' ||
    E'\n          /* 🔴 2026-08-30 堵 A3：手機對得上**不再自動綁**。' ||
    E'\n             不分「對方已綁別的 LINE」與「對方還沒綁」—— 對客人是同一件事：' ||
    E'\n             這支號碼屬於一個不是你的帳號。**一個字都不寫。** */' ||
    E'\n          return jsonb_build_object(''action'',''phone_taken'',' ||
    E'\n            ''message'',''這支手機已經是 MIGI 會員了。請用原本的 LINE 帳號登入，或在櫃檯出示這個畫面由店員協助綁定。'');' ||
    E'\n        end if;',
    'n');
  if v_new = v_old then raise exception '錨點②（not found 那段）沒對上'; end if;

  /* 收尾檢查：不可以還留著會寫入的那一行 */
  if v_new ~ 'set line_user_id = p_line_user_id' then
    raise exception '還有地方會寫 line_user_id，改到一半';
  end if;
  if v_new !~ 'phone_taken' then raise exception '改完之後找不到 phone_taken'; end if;

  execute v_new;
end $$;


/* ============================================================
   驗證（單一 SELECT）

   🎯 **在交易內真的跑一次註冊，最後回滾。**
     只看函式定義裡有沒有 `phone_taken` 是不夠的 ——
     插進註解裡也會是「有」（硬規則 3.5）。

   三個子測試缺一不可：
     ① 拿一個**還沒綁 LINE 的測試帳號的手機** ＋ 一個新的 line_user_id
        → 必須回 `phone_taken`，而且**那個帳號的 line_user_id 不可以被寫進去**
     ② 🎯 正對照：**沒被誤擋** —— 全新的手機要能正常建立
     ③ 🎯 正對照：**同一個人重試**要照樣通（不可以把已綁好的人擋在外面）
   ============================================================ */
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_victim uuid; v_phone text; v_line_after text;
  v_r jsonb; v_a text; v_b text; v_c text;
begin
  select id, phone into v_victim, v_phone from members
   where org_id = v_org and deleted_at is null and line_user_id is null and phone is not null
   order by created_at limit 1;

  if v_victim is null then
    v_a := '🔴 找不到「有手機但沒綁 LINE」的會員 —— 這一格沒驗到';
  else
    -- ① 該擋的
    begin
      v_r := register_member_tx(v_org, '壞人', v_phone, 'U_attacker_test_0830');
      select line_user_id into v_line_after from members where id = v_victim;
      v_a := '回 ' || coalesce(v_r->>'action','?')
          || '　member_id：' || case when v_r ? 'member_id' then '🔴 交出來了' else '✅ 沒給' end
          || '　受害者的 line_user_id：' || case when v_line_after is null then '✅ 還是空的' else '🔴 被寫進去了' end
          || case when v_r->>'action' = 'phone_taken' then '　✅ 擋住了' else '　🔴 沒擋住' end;
    exception when others then v_a := '🔴 直接拋錯：' || sqlerrm;
    end;

    -- ② 正對照：全新手機要能建立
    begin
      v_r := register_member_tx(v_org, '新客人', '0900000199', 'U_newbie_test_0830');
      v_b := '回 ' || coalesce(v_r->>'action','?')
          || case when v_r->>'action' = 'created' then '　✅ 沒被誤擋' else '　🔴 新客人也被擋了' end;
    exception when others then v_b := '🔴 新客人建立失敗：' || sqlerrm;
    end;

    -- ③ 正對照：已經綁好的人再按一次要照樣通
    begin
      v_r := register_member_tx(v_org, '重試', null, 'U_newbie_test_0830');
      v_c := '回 ' || coalesce(v_r->>'action','?')
          || case when v_r->>'action' = 'existing_line' and (v_r ? 'member_id')
                  then '　✅ 照樣通且拿得到自己的 id' else '　🔴 把已綁好的人擋掉了' end;
    exception when others then v_c := '🔴 重試失敗：' || sqlerrm;
    end;
  end if;

  raise exception 'rollback_on_purpose';

exception when others then
  /* 硬規則 3.9：只有設在這裡的 set_config 活得下來 */
  if sqlerrm <> 'rollback_on_purpose' then
    perform set_config('migi.a', '🔴 測試本身失敗：' || sqlerrm, true);
  else
    perform set_config('migi.a', coalesce(v_a,'(空)'), true);
    perform set_config('migi.b', coalesce(v_b,'(空)'), true);
    perform set_config('migi.c', coalesce(v_c,'(空)'), true);
  end if;
end $$;

select 序, 項目, 內容 from (
  select 1 as 序, '① 🎯 用別人的手機註冊（必須被擋，而且不可以寫入）' as 項目,
         coalesce(current_setting('migi.a', true), '🔴 沒跑到') as 內容
  union all
  select 2, '② 🎯 正對照：全新手機沒被誤擋',
         coalesce(current_setting('migi.b', true), '🔴 沒跑到')
  union all
  select 3, '③ 🎯 正對照：已綁好的人再按一次照樣通',
         coalesce(current_setting('migi.c', true), '🔴 沒跑到')
  union all
  select 4, '④ 🎯 正對照：測試資料真的回滾了（應為 0）',
         (select count(*)::text || ' 個 U_..._test_0830 的會員　'
              || case when count(*) = 0 then '✅ 乾淨' else '🔴 有殘留' end
            from members where line_user_id like 'U_%test_0830')
) x order by 序;
