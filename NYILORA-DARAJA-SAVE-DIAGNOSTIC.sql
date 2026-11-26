-- Run only in the Nyilora Supabase SQL Editor.
-- Uses dummy values and always rolls their changes back. Never paste real keys here.
do $$
begin
  begin
    perform public.nyilora_set_c2b_credentials(
      'BIZ-A1C8E7FBD382',
      'DIAGNOSTIC-CONSUMER-KEY',
      'DIAGNOSTIC-CONSUMER-SECRET'
    );
    raise exception 'NYILORA_DIAGNOSTIC_ROLLBACK';
  exception when others then
    if sqlerrm <> 'NYILORA_DIAGNOSTIC_ROLLBACK' then
      raise;
    end if;
  end;
end $$;
