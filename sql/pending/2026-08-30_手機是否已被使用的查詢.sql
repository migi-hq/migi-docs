/* ============================================================
   `phone_in_use_tx`：註冊第 2 步當場檢查手機有沒有人用
   2026-08-30

   ── 為什麼要這一支 ──────────────────────────────────
   修之前，「這支號碼已經有人用」是**填完四步送出之後**才知道的
   （`register_member_tx` 回 `phone_taken`）。
   客人填了暱稱、手機、生日、性別，然後被退回來 —— 那是很差的體驗。
   → 改成在第 2 步按「下一步」時就擋住。

   ── 🔴 它本質上是一個「列舉查詢器」，所以門要關好 ──
   任何「這支號碼是不是會員」的介面，都能被拿來一支一支試。
   三道限制：

   | | |
   |---|---|
   | 誰能呼叫 | **只有 `service_role`** —— 前端叫不動，一定要經過 Edge Function，<br>而那需要一個**驗過簽的 LINE `id_token`** |
   | 回什麼 | **只有一個布林**。不回 `member_id`、不回暱稱、不回任何東西 |
   | 拿到之後能幹嘛 | 🎯 **不能幹嘛** —— A3 已堵，知道某支號碼是會員也綁不進去 |

   📌 這個取捨是業界常態（「這個 email 已經註冊過」到處都是）。
     真正不可接受的是**洩漏身分**，而不是洩漏「有沒有註冊過」。
   ⏳ 之後若要更嚴，是在 Edge Function 加**每個 `line_user_id` 的次數上限**，
     不是把這支函式改回不存在。

   ── ⚠ 正規化只能有一個來源 ──────────────────────────
   查詢**一定要用 `migi_norm_phone()` 正規化後的值**。
   🔴 `uq_members_phone` 是字串比對 —— `0912-345-678` 與 `0912345678`
     會被當成兩個人。2026-08-28 已經為此修過一次 `register_member_tx`，
     那次的教訓是「**查詢與寫入都要用正規化後的值，只做其中一邊等於沒做**」。
   → 所以正規化放在**這一支裡面**，不要讓 Edge Function 或前端自己算 ——
     多一個地方算就多一個會算歪的地方。
   ============================================================ */

create or replace function public.phone_in_use_tx(p_org_id uuid, p_phone text)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_phone text;
begin
  if p_org_id is null or coalesce(trim(p_phone), '') = '' then
    return false;      -- 沒給就當「沒被用」，讓前端照常往下走
  end if;

  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return false;      -- 格式不對是前端自己該擋的事，不在這裡假裝有意見
  end if;

  return exists (
    select 1 from members
     where org_id = p_org_id and phone = v_phone and deleted_at is null
  );
end $$;

/* 硬規則 2.6 ＋ 2.6b：兩個方向都要收。
   PUBLIC 繼承與 Supabase default privileges 的明確授權是兩條不同的路，
   只收一邊是**不會報錯的空操作**。 */
revoke execute on function public.phone_in_use_tx(uuid, text) from public;
revoke execute on function public.phone_in_use_tx(uuid, text) from anon, authenticated;
grant  execute on function public.phone_in_use_tx(uuid, text) to service_role;


/* ============================================================
   驗證（單一 SELECT）

   🎯 **用 anon 的身分實際叫一次**，不是讀 `proacl` ——
     `has_function_privilege` 分不出「明確授權」與「PUBLIC 繼承」（硬規則 2.6）。
   🎯 **正對照缺一不可**：
     ① 已存在的號碼要回 true
     ② 不存在的號碼要回 false　←（沒有這個，一支「永遠回 true」的函式會過關）
     ③ 沒正規化的寫法（`0910-000-001`）也要回 true　← 那正是踩過的坑
     ④ anon 要叫不動，但 `get_wallet_tx` 要還叫得動（沒有誤傷）
   ============================================================ */
do $$
declare v_org uuid := '11111111-1111-1111-1111-111111111111';
        v_p text; v_a text; v_b text;
begin
  select phone into v_p from members
   where org_id = v_org and deleted_at is null and phone is not null
   order by created_at limit 1;

  perform set_config('migi.p', coalesce(v_p, '(找不到有手機的會員)'), true);

  begin
    set local role anon;
    begin
      perform phone_in_use_tx(v_org, '0900000000');
      v_a := '🔴 anon 還是叫得動';
    exception
      when insufficient_privilege then v_a := '✅ permission denied';
      when others then v_a := '⚠ 擋住了但錯誤不同：' || left(sqlerrm, 40);
    end;
    begin
      perform get_wallet_tx('69016205-afde-4036-95a6-5893c9d0e5fe', 1);
      v_b := '✅ 還叫得動（沒有誤傷）';
    exception
      when insufficient_privilege then v_b := '🔴 也被擋了 —— 收過頭了';
      when others then v_b := '✅ 叫得動';
    end;
    reset role;
  exception when others then reset role; v_a := coalesce(v_a, '🔴 切角色失敗');
  end;

  perform set_config('migi.a', coalesce(v_a, '(空)'), true);
  perform set_config('migi.b', coalesce(v_b, '(空)'), true);
end $$;

select 序, 項目, 內容 from (
  select 1 as 序, '① 已存在的號碼（應為 true）' as 項目,
         (select current_setting('migi.p', true) || ' → '
              || phone_in_use_tx('11111111-1111-1111-1111-111111111111',
                                 current_setting('migi.p', true))::text
              || case when phone_in_use_tx('11111111-1111-1111-1111-111111111111',
                                 current_setting('migi.p', true)) then '　✅' else '　🔴' end) as 內容
  union all
  select 2, '② 🎯 正對照：不存在的號碼（應為 false）',
         (select '0900000000 → '
              || phone_in_use_tx('11111111-1111-1111-1111-111111111111','0900000000')::text
              || case when phone_in_use_tx('11111111-1111-1111-1111-111111111111','0900000000')
                      then '　🔴 永遠回 true？' else '　✅' end)
  union all
  select 3, '③ 🎯 正對照：沒正規化的寫法也要認得（應為 true）',
         (select v || ' → ' || phone_in_use_tx('11111111-1111-1111-1111-111111111111', v)::text
              || case when phone_in_use_tx('11111111-1111-1111-1111-111111111111', v)
                      then '　✅' else '　🔴 正規化沒生效' end
            from (select regexp_replace(current_setting('migi.p', true),
                    '^(\d{4})(\d{3})(\d{3})$', '\1-\2-\3') v) t)
  union all
  select 4, '④ 🎯 anon 叫不動，但錢包還叫得動',
         coalesce(current_setting('migi.a', true),'?') || '　／　'
      || coalesce(current_setting('migi.b', true),'?')
) x order by 序;
