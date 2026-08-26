/* ============================================================
   set_my_birthday_tx：讓生日填得進去
   2026-08-26

   ✅ 已執行並驗證通過（2026-08-26）
      DEFINER／anon ✅／版本數 1／四道擋牆都正確回報：
      未來日期 birthday_in_future、空值 birthday_required、
      **會員不存在 member_not_found（不謊報成功）**。

   🔴 但第 ⑤ 項查出 `get_my_profile_tx` **不回傳 birthday** ——
      前端讀不到現值就顯示不了「你已經填過 3/15」，只能永遠空白。
      → 另一支：2026-08-26_profile回傳生日.sql

   ── 為什麼需要 ──────────────────────────────────────
   ```
   members.birthday          欄位在（date），0 / 4 有值
   register_member_tx(...)   🔴 簽名裡沒有 birthday
   migi-web 註冊 form.birth  存 localStorage，沒送後端
   ```
   🔴 2026-08-26 在 POS 會員查詢加了「🎂 生日 N 天後」的膠囊，
     **但那顆永遠不會亮，因為沒有任何地方能填生日**。
     而**生日招待是已承諾的權益**。

   ── 為什麼另開一支，不改 register_member_tx ────────────
   · 生日可以**之後補填**，不該綁在註冊那一刻
     （註冊要快，多一個必填欄位就多一個放棄的理由）
   · 改 register 的簽名要 DROP + 補 GRANT + 部署順序
   · 比照既有的 `set_my_sched_tx(p_org_id, p_member_id, p_sched)`——
     會員自己改自己的資料，本來就是一支一件事

   ── ⚠ 現在允許重複修改，但這是有到期日的決定 ──────────
   🔴 生日招待是**權益**。可以隨時改生日 = 可以隨時領招待。
   但現在不鎖，理由有二：
     ① **今天不可能被濫用**：0 個會員綁 LINE，
        而且生日招待還沒有任何自動化機制（要店員手動給）
     ② **鎖了會讓打錯的人卡住** —— 改要找店員，
        而店員登入卡在 LINE Developers 帳號（PENDING），
        也就是**今天鎖上就沒有人能解**

   → **生日招待自動化之前必須加鎖**（改成 `where birthday is null`，
     修改走店員工具）。已記進 CLAUDE.md 待辦 30。
   ⚠ 加鎖時要記得今天早上的教訓：
     `update ... where birthday is null` 之後**一定要看 `FOUND`**，
     不要無條件回報成功 —— `register_member_tx` 就是這樣謊報了三個月。

   ── 驗證範圍 ────────────────────────────────────────
   下面順帶印出 `get_my_profile_tx` 的回傳，
   確認**會員 App 讀不讀得到生日**（讀不到的話前端沒辦法顯示現值）。
   ============================================================ */

create or replace function public.set_my_birthday_tx(
  p_org_id    uuid,
  p_member_id uuid,
  p_birthday  date
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_n int;
begin
  if p_birthday is null then
    return jsonb_build_object('ok', false, 'reason', 'birthday_required',
      'message', '請選擇生日');
  end if;

  /* 合理範圍。不做年齡限制 —— 那是**營運政策**不是資料規則，
     而且政策會變（例如日後開放親子場）。這裡只擋明顯不可能的值。
     ⚠ 用 current_date 不用 now()：生日是日期不是時間點，
       而 now() 在時區邊界會讓「今天」有兩種答案。 */
  if p_birthday > current_date then
    return jsonb_build_object('ok', false, 'reason', 'birthday_in_future',
      'message', '生日不能是未來的日期');
  end if;
  if p_birthday < date '1900-01-01' then
    return jsonb_build_object('ok', false, 'reason', 'birthday_too_old',
      'message', '請確認生日年份');
  end if;

  update members
     set birthday = p_birthday, updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null;

  /* ★ 看 FOUND，不要無條件回報成功。
     今天早上 register_member_tx 就是因為無條件回報 'rebound'
     而謊報了綁定成功 —— 同一個病不要在同一天犯兩次。 */
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found',
      'message', '找不到這位會員');
  end if;

  return jsonb_build_object('ok', true, 'birthday', p_birthday);
end $function$;

/* 會員 App 用 anon 呼叫（目前還沒有 JWT，見待辦 14）。 */
grant execute on function public.set_my_birthday_tx(uuid, uuid, date)
  to anon, authenticated;


/* ============================================================
   驗證段（單一 SELECT）

   ⚠ 硬規則 7：真的呼叫。用「未來的日期」那條路 ——
     它在碰 members 之前就回 ok:false，**不會改到任何人的資料**。
   ⚠ 硬規則 3.9：訊息設在 exception 處理器裡（這支不拋例外，
     所以直接在 SELECT 裡讀回傳就好）。
   ============================================================ */

select 序, 項目, 結果 from (

  select 0 as 序, '① 函式狀態' as 項目,
         coalesce((select (case when p.prosecdef then '✅ DEFINER' else '🔴 INVOKER' end) ||
                          '　anon ' ||
                          (case when has_function_privilege('anon', p.oid, 'EXECUTE')
                                then '✅' else '🔴 沒有' end) ||
                          '　版本數 ' ||
                          (select count(*)::text from pg_proc q
                            where q.pronamespace = 'public'::regnamespace
                              and q.proname = 'set_my_birthday_tx')
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'set_my_birthday_tx'
                    limit 1), '🔴 不存在') as 結果

  union all
  /* ② 擋牆：未來的日期。不會改到任何資料。 */
  select 0, '② 擋未來日期',
         coalesce((set_my_birthday_tx(gen_random_uuid(), gen_random_uuid(),
                                      current_date + 1) ->> 'reason'), '🔴 沒回 reason')

  union all
  /* ③ 擋牆：null */
  select 0, '③ 擋空值',
         coalesce((set_my_birthday_tx(gen_random_uuid(), gen_random_uuid(),
                                      null) ->> 'reason'), '🔴 沒回 reason')

  union all
  /* ④ 擋牆：會員不存在（驗 FOUND 那段有沒有生效）
        ⚠ 這一項最重要 —— 它驗的正是「不要無條件回報成功」。 */
  select 0, '④ 會員不存在時不會謊報成功',
         coalesce((set_my_birthday_tx(gen_random_uuid(), gen_random_uuid(),
                                      date '1990-01-01') ->> 'reason'), '🔴 沒回 reason')

  union all
  /* ⑤ 會員 App 讀不讀得到生日 —— 讀不到的話前端顯示不了現值。
        ⚠ 這一項不是這支函式的事，是順便查清楚下一步要不要再改一支。 */
  select 1, '⑤ get_my_profile_tx 有沒有回傳 birthday',
         coalesce((select case when pg_get_functiondef(p.oid) ilike '%birthday%'
                               then '✅ 內文有提到 birthday'
                               else '🔴 沒有 —— 前端讀不到現值，要再改一支' end
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'get_my_profile_tx'
                    limit 1), '🔴 get_my_profile_tx 不存在')

  union all
  select 2, '⑥ 現在有幾個人填了生日',
         (select count(*) filter (where birthday is not null)::text
              || ' / ' || count(*)::text
            from members where deleted_at is null)

) x order by 序, 項目;
