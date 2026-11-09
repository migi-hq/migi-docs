/* ============================================================
   有花的局：平胡跟門清不能一起算（2026-11-09 使用者）

   規則：
     無花的局   門清 ＋ 平胡 可以一起算（3 台）              ← 不變
     有花的局   平胡照樣有（手上沒有花才算），但跟門清只能二選一
   （同日一度寫成「有花的局整格拿掉平胡」，使用者更正：「平胡還是有，只是不能門清加平胡」——那一版沒跑過）

   改法：
   ① scoring_patterns 加一欄 flower_conflicts：**有花的局才加上的互斥**；平胡填 {menqing}
      （互斥是雙向看的，只寫在平胡這一列就夠）
   ② _tbl_state_for_device：有花的局把 flower_conflicts 併進回給計分板的 conflicts
      ⇒ 計分板畫面一行都不用改：它本來就照 conflicts「選了一個就取消另一個」
   ③ tbl_submit_hand_tx：送出時的互斥檢查，有花的局一樣併進去（兩處 unnest）
   ④ _tbl_practice_cfg：教學模式固定有花 ⇒ 直接併
   ②③④ 撈線上全文 → 換那幾處 → 換不到就整份不執行（raise，故意不提交）
   ⚠ 已經記下的舊局不重算
   ⚠ 線上好友房引擎（supabase/functions/_shared/mahjong/engine.mjs）同批讀這一欄
   ============================================================ */

alter table public.scoring_patterns add column if not exists flower_conflicts text[] not null default '{}';
comment on column public.scoring_patterns.flower_conflicts is '有花的局才加上的互斥（雙向）。平胡 ＝ {menqing}：有花的局門清與平胡只能二選一';
update public.scoring_patterns set flower_conflicts = array['menqing'], updated_at = now() where code = 'pinghu';

do $$
declare
  v_old text; v_new text;
  c_old constant text := $q$'conflicts', to_jsonb(p.conflicts)) order by p.sort)$q$;
begin
  -- ② 計分板畫面拿到的牌型清單
  v_old := pg_get_functiondef('public._tbl_state_for_device'::regproc);
  v_new := replace(v_old, c_old,
    $q$'conflicts', to_jsonb(p.conflicts || case when coalesce(s.flower, '無花') = '有花' then p.flower_conflicts else '{}'::text[] end)) order by p.sort)$q$);
  if v_new = v_old then raise exception '② _tbl_state_for_device 找不到要換的那一行，整份不執行'; end if;
  execute v_new;

  -- ③ 送出時的互斥檢查（「互斥（雙向）」那一段有兩處 unnest）
  v_old := pg_get_functiondef('public.tbl_submit_hand_tx'::regproc);
  if (length(v_old) - length(replace(v_old, 'unnest(a.conflicts) c', ''))) <> 2 * length('unnest(a.conflicts) c') then
    raise exception '③ tbl_submit_hand_tx 的 unnest(a.conflicts) 不是剛好兩處，整份不執行';
  end if;
  v_new := replace(v_old, 'unnest(a.conflicts) c',
    $q$unnest(a.conflicts || case when coalesce(s.flower, '無花') = '有花' then a.flower_conflicts else '{}'::text[] end) c$q$);
  execute v_new;

  -- ④ 教學模式（固定有花）
  v_old := pg_get_functiondef('public._tbl_practice_cfg'::regproc);
  v_new := replace(v_old, c_old, $q$'conflicts', to_jsonb(p.conflicts || p.flower_conflicts)) order by p.sort)$q$);
  if v_new = v_old then raise exception '④ _tbl_practice_cfg 找不到要換的那一行，整份不執行'; end if;
  execute v_new;
end $$;

/* ── 驗證（單一 SELECT；不用 raise）──────────────────────────── */
select
  case when (select flower_conflicts from scoring_patterns where code = 'pinghu') = array['menqing'] then '✅' else '🔴' end || ' ① 平胡：有花的局跟門清互斥' || E'\n' ||
  case when (select count(*) from scoring_patterns where cardinality(flower_conflicts) > 0) = 1 then '✅' else '🔴' end || ' ② 只有平胡一列有填' || E'\n' ||
  case when (select 'menqing' <> all(conflicts) from scoring_patterns where code = 'pinghu') then '✅' else '🔴' end || ' ③ 正對照：平胡原本的互斥沒有門清（無花的局照樣可以一起算）' || E'\n' ||
  case when pg_get_functiondef('public._tbl_state_for_device'::regproc) ~ 'p\.flower_conflicts' then '✅' else '🔴' end || ' ④ 計分板畫面有花的局併進互斥' || E'\n' ||
  case when (length(pg_get_functiondef('public.tbl_submit_hand_tx'::regproc)) - length(replace(pg_get_functiondef('public.tbl_submit_hand_tx'::regproc), 'a.flower_conflicts', ''))) = 2 * length('a.flower_conflicts') then '✅' else '🔴' end || ' ⑤ 送出時兩處檢查都併進去' || E'\n' ||
  case when pg_get_functiondef('public._tbl_practice_cfg'::regproc) ~ 'p\.flower_conflicts' then '✅' else '🔴' end || ' ⑥ 教學模式併進去' || E'\n' ||
  case when (select count(*) from pg_proc where proname in ('_tbl_state_for_device', 'tbl_submit_hand_tx', '_tbl_practice_cfg')) = 3 then '✅' else '🔴' end || ' ⑦ 三支各只有一個版本' as "驗證";
