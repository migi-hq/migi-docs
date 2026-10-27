/* ============================================================
   智慧計分板：每位玩家多回一個 no1（是不是目前全國第 1 名）
   2026-10-27 · 使用者：全國第一同桌時，第 1 將第 1 局開始播「強者登場」，之後他的卡片名字下面留「目前全國 #1」

   ── 「全國第一」用哪一份排名 ─────────────────────────
   跟會員 App 排行榜**同一支** season_rank_rows_display_tx（本季、rank_no = 1）。
   ⇒ 平板說他是第一，排行榜最上面就是他，兩邊不會對不上。
   · 同分時那支用建立帳號的先後排開 ⇒ 第 1 名只會有一個人
   · 隱藏中的會員不排、測試01～04 不排（那支本來就這樣）；上線前其他測試帳號照樣排（同排行榜）
   · 兩季之間的空檔（沒有進行中的賽季）⇒ 沒有人是 no1

   ── 只改 _tbl_state_for_device 三處，其餘一字不動 ────────
   ① declare 多兩個變數  ② 開場撈一次本季第 1 名  ③ players 每一列多 'no1'
   做法：撈線上全文 → replace → 每一處都確認真的換到（沒換到就 raise，整份回滾、線上不動）。
   簽名不變（CREATE OR REPLACE）⇒ 權限不會掉。
   ⚠ 不回 member_id 那條規矩照舊：no1 是布林值，不是會員 id。
   ============================================================ */

do $$
declare
  v_old text;
  v_new text;
begin
  v_old := pg_get_functiondef('public._tbl_state_for_device(table_devices)'::regprocedure);
  v_new := v_old;

  -- ① 變數
  v_new := replace(v_new,
    'v_rounds jsonb; v_catalog jsonb; v_stake jsonb; v_last_reject jsonb; v_log jsonb;',
    'v_rounds jsonb; v_catalog jsonb; v_stake jsonb; v_last_reject jsonb; v_log jsonb;' || chr(10) ||
    '  v_no1 uuid; v_season jsonb;   -- 🏆 本季全國第一（2026-10-27）');
  if v_new = v_old then raise exception '① 變數那一行對不上，沒有換到'; end if;
  v_old := v_new;

  -- ② 開場撈一次本季第 1 名（放在組 players 之前）
  v_new := replace(v_new,
    '  /* 不回 member_id —— 平板認人用的是 player_id',
    '  /* 🏆 本季全國第一（2026-10-27）：跟排行榜同一支 season_rank_rows_display_tx，rank_no = 1 只會有一個人。' || chr(10) ||
    '     沒有進行中的賽季 ⇒ v_no1 是 null ⇒ 沒有人是 no1 */' || chr(10) ||
    '  v_season := public.current_season_tx(s.org_id);' || chr(10) ||
    '  if v_season is not null then' || chr(10) ||
    '    select r.member_id into v_no1' || chr(10) ||
    '      from public.season_rank_rows_display_tx(s.org_id, (v_season ->> ''starts_at'')::timestamptz, null) r' || chr(10) ||
    '     where r.rank_no = 1 order by r.member_id limit 1;' || chr(10) ||
    '  end if;' || chr(10) || chr(10) ||
    '  /* 不回 member_id —— 平板認人用的是 player_id');
  if v_new = v_old then raise exception '② 插入點（不回 member_id 那段註解）對不上，沒有換到'; end if;
  v_old := v_new;

  -- ③ players 每一列多 no1（布林，不是會員 id）
  v_new := replace(v_new,
    '''team'', public._tbl_member_team(sp.member_id))',
    '''team'', public._tbl_member_team(sp.member_id),' || chr(10) ||
    '           ''no1'', v_no1 is not null and sp.member_id = v_no1)   -- 🏆 目前全國第一（2026-10-27）');
  if v_new = v_old then raise exception '③ players 的 team 那一行對不上，沒有換到'; end if;

  execute v_new;
end $$;

/* ── 驗證（單一 SELECT，不 raise）──────────────────────── */
select
  case when (select count(*) from pg_proc where proname = '_tbl_state_for_device' and pronamespace = 'public'::regnamespace) = 1
       then '✅ ① 只有一個版本' else '🔴 ① 版本數不是 1' end
  || E'\n' ||
  case when pg_get_functiondef('public._tbl_state_for_device(table_devices)'::regprocedure) ~ '''no1'', v_no1 is not null'
        and pg_get_functiondef('public._tbl_state_for_device(table_devices)'::regprocedure) ~ 'season_rank_rows_display_tx'
       then '✅ ② 函式裡有 no1，排名用的是排行榜那一支' else '🔴 ② 改動沒有進去' end
  || E'\n' ||
  /* ③ 拿一張現在有牌局的桌子實際叫一次：每位玩家都有 no1 鍵、最多一個人是 true */
  coalesce((
    select case when bool_and(p ? 'no1') and count(*) filter (where (p ->> 'no1')::boolean) <= 1
                then '✅ ③ 實際叫一次：' || count(*) || ' 位玩家都有 no1，其中 ' || count(*) filter (where (p ->> 'no1')::boolean) || ' 位是全國第一'
                else '🔴 ③ 有玩家沒有 no1，或不只一個人是 true' end
      from (select d from table_devices d
             join table_sessions ts on ts.table_id = d.table_id and ts.status = 'open' and ts.deleted_at is null
             where d.kind = 'tablet' and d.revoked_at is null
             limit 1) x,
           jsonb_array_elements(public._tbl_state_for_device(x.d) -> 'players') p),
    '⚪ ③ 現在沒有開著牌局的桌子，實際叫不了（等有牌局時再看）')
  || E'\n' ||
  /* ④ 權限沒有被動到：前端角色仍然叫不到這支內部函式 */
  case when not has_function_privilege('anon', 'public._tbl_state_for_device(table_devices)', 'execute')
        and not has_function_privilege('authenticated', 'public._tbl_state_for_device(table_devices)', 'execute')
       then '✅ ④ 前端角色仍然叫不到這支（只經由 tbl_state_tx／pos_tbl_watch_tx）' else '⚠ ④ 前端角色叫得到這支，核對一下是不是原本就這樣' end
  as "驗證";
