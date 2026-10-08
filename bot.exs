Code.require_file("utils/json.ex", __DIR__)
Code.require_file("utils/banner.ex", __DIR__)

defmodule SibleNetwork do
  @moduledoc false

  @my_project "Sible Network Miniapp"
  @base_url "https://prod.sible.network/api/v1"
  @web_origin "https://mine.sible.network"
  @root __DIR__

  @reset "\e[0m"
  @bold "\e[1m"
  @red "\e[91m"
  @green "\e[92m"
  @yellow "\e[93m"

  def run do
    :logger.set_primary_config(:level, :error)
    install_signal_handler()

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    Banner.set_title(@my_project)
    Banner.show_banner(@my_project)

    accounts = load_lines("data.txt")

    cond do
      accounts == [] ->
        red("File data.txt is empty, please add your refresh token entries")
        System.halt(1)

      true ->
        proxies = load_lines("proxy.txt")
        settings = load_settings()

        loop(proxies, settings, 1)
    end
  end

  defp loop(proxies, settings, cycle) do
    accounts = load_lines("data.txt")

    yellow("Starting automation cycle number #{cycle}")

    Enum.with_index(accounts)
    |> Enum.each(fn {account, index} ->
      if index > 0, do: IO.puts("")

      proxy = proxy_for(proxies, index)

      case proxy do
        nil -> :ok
        line -> yellow("Using proxy #{mask_proxy(line)}")
      end

      process_account(account, index, proxy)
    end)

    yellow("All accounts processed for cycle number #{cycle}")

    wait = sleep_seconds(settings)
    countdown(wait, "Next cycle starts in")
    Banner.show_banner(@my_project)
    loop(proxies, settings, cycle + 1)
  end

  defp process_account(account, index, proxy) do
    label = "account #{index + 1}"

    case open_session(account, index, proxy) do
      {:ok, state} ->
        user = state.user

        cond do
          get(user, "status", "active") != "active" ->
            red("#{String.capitalize(label)} is not active and was skipped by the bot")

          true ->
            green(
              "Welcome back #{clean_text(get(user, "username", "Unknown"), "user")} with #{money(get(user, "balance", 0))} points"
            )

            state
            |> run_mining(proxy)
            |> run_reward_tasks(proxy)
            |> report_totals(proxy)
        end

        :ok

      {:error, reason} ->
        red("Failed to open a session for #{label} with #{clean_text(reason, "error")}")
    end
  end

  defp open_session(account, index, proxy) do
    case call("/auth/refresh", %{"refreshToken" => account}, nil, proxy) do
      {:ok, body} ->
        token = get(body, "accessToken")
        rotated = get(body, "refreshToken", account)

        if rotated != account, do: save_token(index, rotated)

        case call("/users/me", nil, token, proxy, "GET") do
          {:ok, user} ->

            {:ok, %{token: token, refresh: rotated, user: user, index: index}}

          {:banned, _body} ->
            {:error, "a blocked or restricted account"}

          {:refused, _body} ->
            {:error, "a refused account profile request"}

          {:error, reason} ->
            {:error, reason}
        end

      {:banned, _body} ->
        {:error, "a blocked or restricted account"}

      {:refused, body} ->
        {:error, error_text(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_mining(state, proxy) do
    case call("/mining/status", nil, state.token, proxy, "GET") do
      {:ok, status} ->
        cond do
          not get(status, "enabled", false) ->
            yellow("Mining is currently disabled on this server")
            state

          true ->
            state
            |> run_ad_boosts(status, proxy)
            |> run_mining_claim(proxy)
            |> run_mining_start(proxy)
        end

      {:refused, _body} ->
        yellow("Mining status is not available for this account right now")
        state

      {:error, reason} ->
        red("Mining status request failed with #{clean_text(reason, "error")}")
        state
    end
  end

  defp run_ad_boosts(state, status, proxy) do
    limit = get(status, "adMaxPerSession", 3)
    run_ad_boosts(state, status, proxy, 0, limit)
  end

  defp run_ad_boosts(state, status, proxy, watched, limit) when watched < 3 and watched < limit do
    cond do
      not get(status, "canWatchAd", false) ->
        if watched > 0 do
          green("Ad boost finished on this account with #{plural(watched, "rewarded video")} watched")
        else
          yellow("No ad boost is available on this account right now")
        end

        state

      true ->
        if watched > 0, do: pace(30, "Next ad in")

        case call("/mining/ad", %{}, state.token, proxy) do
          {:ok, body} ->
            green("Rewarded video was watched and the hourly mining rate is now #{money(get(body, "currentHourlyReward", 0))} points per hour")
            run_ad_boosts(state, body, proxy, watched + 1, limit)

          {:refused, body} ->
            yellow("Ad boost was refused with #{clean_text(error_text(body), "a server refusal")} and it was skipped for this account")
            state

          {:error, reason} ->
            red("Ad boost failed with #{clean_text(reason, "error")}")
            state
        end
    end
  end

  defp run_ad_boosts(state, _status, _proxy, watched, _limit) do
    if watched > 0 do
      green("Ad boost finished on this account with #{plural(watched, "rewarded video")} watched")
    else
      yellow("No ad boost is available on this account right now")
    end

    state
  end

  defp run_mining_claim(state, proxy) do
    case call("/mining/status", nil, state.token, proxy, "GET") do
      {:ok, status} ->
        cond do
          not get(status, "canClaim", false) ->
            yellow("No mining reward is ready to be claimed on this account yet")
            state

          true ->
            case call("/mining/claim", %{}, state.token, proxy) do
              {:ok, body} ->
                settle_claim(state, body, proxy)

              {:empty, _body} ->
                yellow("No mining reward is ready to be claimed on this account yet")
                state

              {:refused, body} ->
                yellow("Mining claim was refused with #{clean_text(error_text(body), "a server refusal")} and it was skipped for this account")
                state

              {:error, reason} ->
                red("Mining claim failed with #{clean_text(reason, "error")}")
                state
            end
        end

      _other ->
        state
    end
  end

  defp settle_claim(state, body, proxy) do
    claim_id = get(body, "claimId")

    cond do
      is_nil(claim_id) ->
        green("Mining reward was claimed for #{money(get(body, "amount", 0))} points")

        refresh_user(state, proxy)

      true ->
        settle_claim_poll(state, claim_id, proxy, [500, 1000, 2000, 4000])
    end
  end

  defp settle_claim_poll(state, claim_id, proxy, [delay | rest]) do
    pace_ms(delay, "Next mining claim check in")

    case call("/mining/claim/#{claim_id}", nil, state.token, proxy, "GET") do
      {:ok, body} ->
        cond do
          get(body, "status", "settled") != "pending" ->
            green("Mining reward was settled for #{money(get(body, "amount", 0))} points")

            refresh_user(state, proxy)

          rest == [] ->
            yellow("Mining reward is still settling on the server and was left for the next cycle")
            state

          true ->
            settle_claim_poll(state, claim_id, proxy, rest)
        end

      _other ->
        yellow("Mining reward is still settling on the server and was left for the next cycle")
        state
    end
  end

  defp settle_claim_poll(state, _claim_id, _proxy, []) do
    yellow("Mining reward is still settling on the server and was left for the next cycle")
    state
  end

  defp run_mining_start(state, proxy) do
    case call("/mining/status", nil, state.token, proxy, "GET") do
      {:ok, status} ->
        cond do
          get(status, "canActivate", false) ->
            case call("/mining/start", %{}, state.token, proxy) do
              {:ok, body} ->
                green("A new mining session was started and the hourly rate is #{money(get(body, "currentHourlyReward", 0))} points per hour")
                state

              {:used, _body} ->
                yellow("This mining slot was already activated on this account today")
                state

              {:refused, body} ->
                yellow("Mining session start was refused with #{clean_text(error_text(body), "a server refusal")} and it was skipped for this account")
                state

              {:error, reason} ->
                red("Mining session start failed with #{clean_text(reason, "error")}")
                state
            end

          true ->
            state
        end

      _other ->
        state
    end
  end

  defp run_reward_tasks(state, proxy) do
    case call("/reward-tasks", nil, state.token, proxy, "GET") do
      {:ok, body} ->
        items = get(body, "items", [])
        day_key = get(body, "dayKey")

        pending =
          items
          |> Enum.reject(&get(&1, "completed", false))
          |> Enum.reject(&(get(&1, "lockedReason", nil) != nil))
          |> Enum.reject(&(get(&1, "eligible", true) == false))

        cond do
          items == [] ->
            yellow("No account task is available on this account yet")
            state

          pending == [] ->
            if Enum.all?(items, &get(&1, "completed", false)) do
              yellow("Every available account task was already completed")
            else
              yellow("No account task is ready to be claimed on this account yet")
            end

            state

          true ->
            claimed = Enum.reduce(pending, {state, 0, 0}, fn task, acc -> claim_task(task, day_key, acc, proxy) end)

            {state, done, missed} = claimed

            if missed > 0 do
              yellow("#{plural(missed, "account task")} could not be completed on this run")
            end

            if done > 0 do
              green(
                "All available tasks completed for this account and #{plural(done, "reward")} #{if done == 1, do: "was", else: "were"} claimed"
              )
            end

            state
        end

      {:refused, _body} ->
        yellow("Account task list is not available for this account right now")
        state

      {:error, reason} ->
        red("Account task list request failed with #{clean_text(reason, "error")}")
        state
    end
  end

  defp claim_task(task, day_key, {state, done, missed}, proxy) do
    title = clean_text(get(task, "title", "account task"), "account task")

    case run_task(task, day_key, state, proxy) do
      {:ok, reward} ->
        green("Account task #{title} was claimed for #{money(reward)} points")
        pace(2, "Next account task in")
        {state, done + 1, missed}

      {:skipped, reason} ->
        yellow("Account task #{title} was skipped with #{clean_text(reason, "a server refusal")}")
        {state, done, missed + 1}

      {:failed, reason} ->
        red("Account task #{title} failed with #{clean_text(reason, "error")}")
        {state, done, missed}
    end
  end

  defp run_task(task, day_key, state, proxy) do
    id = get(task, "id")
    reward = get(task, "reward", 0)
    action = get(task, "action", "")

    cond do
      action == "referral" ->
        {:skipped, "a referral task"}

      get(task, "needsSubmission", false) ->
        submit_social_task(task, day_key, id, reward, state, proxy)

      true ->
        claim_reward_task(id, day_key, reward, state, proxy)
    end
  end

  defp submit_social_task(task, day_key, id, reward, state, proxy) do
    case call("/reward-tasks/#{id}/open", %{}, state.token, proxy) do
      {:ok, opened} ->
        wait = get(opened, "waitSeconds", get(task, "waitSeconds", 10))

        countdown(trunc_number(wait, 10), "Next account task in")

        case social_links(task) do
          [] ->
            {:skipped, "an unsupported social platform"}

          links ->
            case call("/reward-tasks/#{id}/submissions", %{"links" => links}, state.token, proxy) do
              {:ok, submitted} ->
                if get(submitted, "credited", false) do
                  {:ok, get(submitted, "reward", reward)}
                else
                  claim_reward_task(id, day_key, reward, state, proxy)
                end

              {:refused, body} ->
                yellow("Account task #{clean_text(get(task, "title", "account task"), "account task")} submission was refused with #{clean_text(error_text(body), "a server refusal")}")
                {:skipped, "a refused link submission"}

              {:error, reason} ->
                {:failed, reason}
            end
        end

      {:refused, body} ->
        {:skipped, error_text(body)}

      {:error, reason} ->
        {:failed, reason}
    end
  end

  defp social_links(task) do
    platforms = get(get(task, "submissionConfig", %{}), "platforms", [])
    url = get(task, "url")

    case {platforms, url} do
      {[platform | _rest], url} when is_binary(url) ->
        [%{"platformId" => get(platform, "id"), "url" => url}]

      _other ->
        []
    end
  end

  defp claim_reward_task(id, day_key, reward, state, proxy) do
    payload =
      case day_key do
        value when is_binary(value) and value != "" -> %{"dayKey" => value}
        _other -> %{}
      end

    case call("/reward-tasks/#{id}/claim", payload, state.token, proxy) do
      {:ok, _body} ->
        {:ok, reward}

      {:wait, seconds} ->
        yellow("Account task #{clean_text(id, "task")} must wait #{plural(seconds, "second")} before it can be claimed")

        countdown(seconds, "Next account task in")

        case call("/reward-tasks/#{id}/claim", payload, state.token, proxy) do
          {:ok, _body} -> {:ok, reward}
          _other -> {:skipped, "a task waiting time"}
        end

      {:open_required, _body} ->
        case call("/reward-tasks/#{id}/open", %{}, state.token, proxy) do
          {:ok, opened} ->
            wait = trunc_number(get(opened, "waitSeconds", 0), 0)
            if wait > 0, do: countdown(wait, "Next account task in")

            case call("/reward-tasks/#{id}/claim", payload, state.token, proxy) do
              {:ok, _body} -> {:ok, reward}
              _other -> {:skipped, "a task open requirement"}
            end

          _other ->
            {:skipped, "a task open requirement"}
        end

      {:refused, body} ->
        {:skipped, error_text(body)}

      {:error, reason} ->
        {:failed, reason}
    end
  end

  defp report_totals(state, proxy) do
    case call("/users/me", nil, state.token, proxy, "GET") do
      {:ok, body} ->
        green(
          "Account finished with #{money(get(body, "balance", 0))} points and #{money(get(state.user, "balance", 0))} points at the start of the cycle"
        )

        %{state | user: body}

      _other ->
        state
    end
  end

  defp refresh_user(state, proxy) do
    case call("/users/me", nil, state.token, proxy, "GET") do
      {:ok, body} -> %{state | user: body}
      _other -> state
    end
  end

  defp error_text(body) do
    case get(get(body, "error", %{}), "message", nil) do
      value when is_binary(value) and value != "" -> value
      _other -> "a server refusal"
    end
  end

  defp call(path, payload, token, proxy, method \\ "POST") do
    case request(path, payload, token, proxy, method) do
      {:ok, _status, body} -> classify(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(path, payload, token, proxy, method) do
    url = String.to_charlist(@base_url <> path)

    headers =
      [
        {~c"accept", ~c"application/json"},
        {~c"accept-language", ~c"en-US,en;q=0.9"},
        {~c"content-type", ~c"application/json"},
        {~c"origin", String.to_charlist(@web_origin)},
        {~c"referer", String.to_charlist(@web_origin <> "/")},
        {~c"x-client-type", ~c"web"},
        {~c"user-agent",
         ~c"Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36"}
      ] ++ auth_header(token)

    {profile, auth} = proxy_setup(proxy)
    options = [ssl: [verify: :verify_none], timeout: 30_000, connect_timeout: 15_000] ++ auth

    outcome =
      if method == "GET" do
        :httpc.request(:get, {url, headers}, options, [body_format: :binary], profile)
      else
        :httpc.request(
          :post,
          {url, headers, ~c"application/json", encode(payload)},
          options,
          [body_format: :binary],
          profile
        )
      end

    case outcome do
      {:ok, {{_, status, _}, _, response}} ->
        {:ok, status, decode_or_empty(response)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp auth_header(nil), do: []

  defp auth_header(token) do
    [{~c"authorization", String.to_charlist("Bearer " <> token)}]
  end

  defp encode(nil), do: ~c"{}"

  defp encode(payload) do
    payload
    |> YuurisanJSON.encode()
    |> String.to_charlist()
  end

  defp decode_or_empty(response) do
    case YuurisanJSON.decode(response) do
      {:ok, value} -> value
      {:error, _} -> %{}
    end
  end

  defp classify(body) do
    cond do
      get(body, "success", false) ->
        {:ok, get(body, "data", %{})}

      true ->
        classify_error(get(get(body, "error", %{}), "code", nil), body)
    end
  end

  defp classify_error(code, body) do
    lowered = if is_binary(code), do: String.downcase(code), else: ""

    cond do
      String.contains?(lowered, "banned") or String.contains?(lowered, "locked") ->
        {:banned, body}

      String.contains?(lowered, "token_invalid") or String.contains?(lowered, "unauthorized") ->
        {:refused, body}

      String.contains?(lowered, "slot_already_used") ->
        {:used, body}

      String.contains?(lowered, "not_ready") or String.contains?(lowered, "nothing_to_claim") ->
        {:empty, body}

      String.contains?(lowered, "wait_required") ->
        {:wait, get(get(body, "error", %{}), "retryAfterSec", 10)}

      String.contains?(lowered, "open_required") ->
        {:open_required, body}

      true ->
        {:refused, body}
    end
  end

  defp proxy_setup(nil), do: {:default, []}

  defp proxy_setup(line) do
    case parse_proxy(line) do
      {host, port, user, pass} -> proxy_profile(host, port, user, pass)
      {host, port} -> proxy_profile(host, port, "", "")
      nil -> {:default, []}
    end
  end

  defp proxy_profile(host, port, user, pass) do
    name = String.to_atom("proxy_#{host}_#{port}")
    address = {String.to_charlist(host), port}

    case :inets.start(:httpc, profile: name) do
      {:ok, _pid} -> :httpc.set_options([proxy: {address, []}, https_proxy: {address, []}], name)
      {:error, {:already_started, _pid}} -> :ok
      _other -> :ok
    end

    case user do
      "" -> {name, []}
      _ -> {name, [proxy_auth: {String.to_charlist(user), String.to_charlist(pass)}]}
    end
  end

  defp parse_proxy(line) do
    value =
      line
      |> String.trim()
      |> String.replace_prefix("http://", "")
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("socks5://", "")

    case String.split(value, "@") do
      [credentials, host_part] ->
        case String.split(credentials, ":") do
          [user, pass] -> with_host_port(host_part, user, pass)
          _other -> with_host_port(host_part, "", "")
        end

      [host_part] ->
        case String.split(host_part, ":") do
          [host, port] -> with_port(host, port)
          [host, port, user, pass] -> with_port_creds(host, port, user, pass)
          _other -> nil
        end
    end
  end

  defp with_host_port(host_part, user, pass) do
    case String.split(host_part, ":") do
      [host, port] -> with_port_creds(host, port, user, pass)
      _other -> nil
    end
  end

  defp with_port(host, port) do
    case Integer.parse(port) do
      {number, ""} -> {host, number}
      _other -> nil
    end
  end

  defp with_port_creds(host, port, user, pass) do
    case Integer.parse(port) do
      {number, ""} -> {host, number, user, pass}
      _other -> nil
    end
  end

  defp mask_proxy(line) do
    case parse_proxy(line) do
      {host, port, _user, _pass} -> "http://user:pass@#{mask_host(host)}:#{port}"
      {host, port} -> "http://user:pass@#{mask_host(host)}:#{port}"
      nil -> "http://user:pass@***:***"
    end
  end

  defp mask_host(host) do
    parts = String.split(host, ".")

    case parts do
      [a, _b, _c, d] ->
        "#{a}*****#{d}"

      _other ->
        if String.length(host) > 4 do
          String.slice(host, 0, 2) <> "*****" <> String.slice(host, -2, 2)
        else
          "***"
        end
    end
  end

  defp proxy_for([], _index), do: nil

  defp proxy_for(proxies, index) do
    Enum.at(proxies, rem(index, length(proxies)))
  end

  defp to_number(value, _fallback) when is_number(value), do: value

  defp to_number(value, fallback) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> fallback
    end
  end

  defp to_number(_value, fallback), do: fallback

  defp trunc_number(value, fallback) do
    case to_number(value, fallback) do
      number when is_integer(number) -> number
      number when is_float(number) -> trunc(number)
      _other -> fallback
    end
  end

  defp money(value) do
    :erlang.float_to_binary(to_number(value, 0.0) * 1.0, decimals: 2)
  end

  defp load_lines(name) do
    case File.read(Path.join(@root, name)) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:error, _reason} ->
        []
    end
  end

  defp save_token(index, token) do
    path = Path.join(@root, "data.txt")

    case File.read(path) do
      {:ok, content} ->
        {lines, _seen} =
          content
          |> String.split("\n")
          |> Enum.reduce({[], 0}, fn line, {acc, seen} ->
            cond do
              String.trim(line) == "" -> {acc ++ [line], seen}
              seen == index -> {acc ++ [token], seen + 1}
              true -> {acc ++ [line], seen + 1}
            end
          end)

        File.write(path, Enum.join(lines, "\n"))

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  defp load_settings do
    case File.read(Path.join(@root, "config.json")) do
      {:ok, content} ->
        case YuurisanJSON.decode(content) do
          {:ok, value} -> value
          {:error, _reason} -> default_settings()
        end

      {:error, _reason} ->
        settings = default_settings()
        File.write(Path.join(@root, "config.json"), YuurisanJSON.encode(settings))
        settings
    end
  end

  defp default_settings, do: %{"settings" => %{"sleep_seconds" => 3600}}

  defp sleep_seconds(settings) do
    case get(get(settings, "settings", %{}), "sleep_seconds", 3600) do
      value when is_integer(value) and value > 0 -> value
      value when is_float(value) and value > 0 -> trunc(value)
      _other -> 3600
    end
  end

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_other, _key, default), do: default

  defp clean_text(value, fallback) when is_list(value) do
    clean_text(List.to_string(value), fallback)
  end

  defp clean_text(value, fallback) when is_atom(value) do
    clean_text(Atom.to_string(value), fallback)
  end

  defp clean_text(value, fallback) when is_number(value) do
    clean_text(to_string(value), fallback)
  end

  defp clean_text(value, fallback) when is_binary(value) do
    text =
      value
      |> String.replace(
        ["[", "]", "|", "#", "!", "@", "$", "%", "^", "&", "*", "(", ")", "-"],
        " "
      )

    case String.split(text) |> Enum.join(" ") do
      "" -> fallback
      cleaned -> cleaned
    end
  end

  defp clean_text(_value, fallback), do: fallback

  defp install_signal_handler do
    handler = fn ->
      IO.write("\n" <> @red <> @bold <> "Script stopped by user" <> @reset <> "\n")
      System.halt(0)
    end

    try do
      System.trap_signal(:sigterm, handler)
    rescue
      _error -> :ok
    end

    try do
      System.trap_signal(:sigquit, handler)
    rescue
      _error -> :ok
    end

    try do
      System.trap_signal(:sighup, handler)
    rescue
      _error -> :ok
    end
  end

  defp plural(count, word) when is_integer(count) do
    if count == 1 do
      "#{count} #{word}"
    else
      "#{count} #{pluralize(word)}"
    end
  end

  defp plural(_count, word), do: "0 #{pluralize(word)}"

  defp pluralize(word) do
    if String.ends_with?(word, "y") and not vowel_before_y?(word) do
      String.slice(word, 0, String.length(word) - 1) <> "ies"
    else
      word <> "s"
    end
  end

  defp vowel_before_y?(word) do
    length = String.length(word)

    if length < 2 do
      false
    else
      String.slice(word, length - 2, 1) in ["a", "e", "i", "o", "u"]
    end
  end

  defp pace(seconds, label) do
    countdown(seconds, label)
    :ok
  end

  defp pace_ms(milliseconds, label) do
    if milliseconds >= 1000 do
      countdown(div(milliseconds, 1000), label)
    else
      :timer.sleep(milliseconds)
    end

    :ok
  end

  defp countdown(seconds, label) do
    left = max(seconds, 0)

    if left >= 1 do
      width = frame(label, left, 0)
      tick(left, label, width)
    end
  end

  defp tick(0, _label, width) do
    IO.write("\r" <> String.duplicate(" ", width) <> "\r")
  end

  defp tick(left, label, width) do
    width = frame(label, left, width)
    :timer.sleep(1000)
    tick(left - 1, label, width)
  end

  defp frame(label, left, width) do
    text = label <> " " <> format_duration(left)
    IO.write("\r" <> @yellow <> @bold <> text <> @reset)
    max(width, String.length(text))
  end

  defp format_duration(total) do
    days = div(total, 86_400)
    hours = div(rem(total, 86_400), 3600)
    minutes = div(rem(total, 3600), 60)
    seconds = rem(total, 60)

    if days > 0 do
      pad(days) <> ":" <> pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    else
      pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    end
  end

  defp pad(value), do: String.pad_leading(Integer.to_string(value), 2, "0")

  defp green(message), do: IO.puts(@green <> @bold <> message <> @reset)
  defp yellow(message), do: IO.puts(@yellow <> @bold <> message <> @reset)
  defp red(message), do: IO.puts(@red <> @bold <> message <> @reset)
end

SibleNetwork.run()
