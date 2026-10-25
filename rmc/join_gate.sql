-- [skv] The join-approval gate, as `ytctl --batch` installs it on a real node
-- (yt-pgxt ytctl/src/actions/join_gate.rs, JoinGateAction): `ytctl --skv-approve`
-- writes `ok:...` into the J row, and only this trigger hands it to the leader,
-- which arms the join. This layout writes its config rows by hand, so that action
-- never runs - without the trigger every approval printed "Approved" and armed
-- nothing: no member ever held master key v1, no lower CA was countersigned
-- (the nightlies of 2026-10-17). lib.sh schema_sql applies it on every node.
--
-- Byte-identical to join_gate_sql("public.yt_config"), like ../topology/pg_setup.sql;
-- ytctl's test the_rmc_fixture_carries_the_same_sql compares the two.

create or replace function yt_join_gate() returns trigger as $yt_join_gate$
declare v jsonb;
begin
    -- a replicated apply: the leader took the approval where it was written
    if coalesce(current_setting('yt.node', true), '') = 'local' then
        return new;
    end if;
    -- [approve] the leader takes the approval as the row is written: it checks it
    -- against the entry it holds and arms it, or the write is refused
    if new.value = 'ok' or new.value like 'ok:%' then
        if inet_client_addr() is not null then
            raise exception 'yt_join: an approval must come from a local connection';
        end if;
        v := (yt_info('J=:' || new.name || ' ' || new.value) -> 0 ->> 'value')::jsonb;
        if not coalesce((v->>'ok')::bool, false) then
            raise exception 'yt_join: %', coalesce(v->>'reason', 'refused');
        end if;
    end if;
    return new;
end $yt_join_gate$ language plpgsql;

drop trigger if exists yt_join_gate on public.yt_config;
create trigger yt_join_gate before update on public.yt_config
    for each row when (new.module = 'J')
    execute function yt_join_gate();
