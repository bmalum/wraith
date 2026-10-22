defmodule WraithWeb.MembersTest do
  use WraithWeb.ConnCase, async: false
  import Swoosh.TestAssertions

  alias Wraith.{Billing, Content, Members, Newsletter, Settings, Tokens}

  setup do
    # mail sent from LiveView processes lands in the test process too
    set_swoosh_global()
    owner = owner_fixture()
    %{owner: owner}
  end

  test "a confirmed member's welcome mail carries an unsubscribe link that works", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/subscribe")
    view |> form("#subscribe-form", %{email: "r@x.io", name: "R"}) |> render_submit()
    member = Members.get_by_email("r@x.io")
    refute member["subscribed"]
    {:ok, member} = Members.confirm(member)
    assert member["subscribed"]
    Newsletter.send_welcome(member)

    assert_email_sent(fn email ->
      assert email.subject =~ "Welcome to Wraith" or email.subject =~ "Confirm"
      email.subject =~ "Welcome to Wraith" or (send(self(), {:email, email}) && true)
    end)

    assert_email_sent(fn email ->
      assert email.subject == "Welcome to Wraith"
      assert {"R", "r@x.io"} in email.to
      assert email.html_body =~ "/members/unsubscribe/"
      [_, token] = Regex.run(~r{/members/unsubscribe/([\w\-\.]+)}, email.html_body)
      conn = get(build_conn(), ~p"/members/unsubscribe/#{token}")
      assert redirected_to(conn) == ~p"/"
      refute Members.get(member["id"])["subscribed"]
      true
    end)
  end

  test "magic link sign-in: request, mail, click, session, account page, sign out", %{conn: conn} do
    {:ok, m} = Members.create(%{email: "m@x.io", name: "M"})
    {:ok, view, html} = live(conn, ~p"/members")
    assert html =~ "Send me a sign-in link"
    view |> form("#member-login-form", %{email: "m@x.io"}) |> render_submit()
    assert render(view) =~ "a sign-in link is on its way"

    assert_email_sent(fn email ->
      assert email.subject =~ "Sign in to"
      [_, token] = Regex.run(~r{/members/login/([\w\-\.]+)}, email.html_body)
      conn = get(build_conn(), ~p"/members/login/#{token}")
      assert redirected_to(conn) == ~p"/members"
      assert get_session(conn, :member_token)

      {:ok, _, html} = live(conn, ~p"/members")
      assert html =~ "m@x.io"
      assert html =~ "Sign out"
      assert html =~ "Account", "the masthead switches to Account"

      conn = post(conn, ~p"/members/logout")
      assert redirected_to(conn) == ~p"/"
      true
    end)

    # unknown addresses get the same answer and no mail
    {:ok, view, _} = live(build_conn(), ~p"/members")
    view |> form("#member-login-form", %{email: "nobody@x.io"}) |> render_submit()
    assert render(view) =~ "a sign-in link is on its way"
    refute_email_sent()
    _ = m
  end

  test "an expired or forged link is refused", %{conn: conn} do
    conn = get(conn, ~p"/members/login/garbage")
    assert redirected_to(conn) == ~p"/members"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not valid"

    assert {:error, :invalid} = Tokens.verify(:member_login, Tokens.sign(:unsubscribe, "x")),
           "purposes are not interchangeable"
  end

  test "paywall tiers: members read members-only, only paid read paid", %{
    conn: conn,
    owner: owner
  } do
    members_post = post_fixture(owner, %{title: "For members", visibility: "members"})
    paid_post = post_fixture(owner, %{title: "For payers", visibility: "paid"})
    {:ok, free} = Members.create(%{email: "free@x.io"})
    {:ok, paid} = Members.create(%{email: "paid@x.io", status: "paid"})

    {:ok, _, html} = live(conn, ~p"/#{members_post["slug"]}")
    assert html =~ "for members"
    refute html =~ ~s(class="prose-wraith")

    as_free = log_in_member(conn, free)
    {:ok, _, html} = live(as_free, ~p"/#{members_post["slug"]}")
    assert html =~ ~s(class="prose-wraith")
    {:ok, _, html} = live(as_free, ~p"/#{paid_post["slug"]}")
    assert html =~ "paid members"
    refute html =~ ~s(class="prose-wraith")

    as_paid = log_in_member(conn, paid)
    {:ok, _, html} = live(as_paid, ~p"/#{paid_post["slug"]}")
    assert html =~ ~s(class="prose-wraith")
  end

  test "publishing and sending a newsletter mails subscribed members who may read it", %{
    conn: conn,
    owner: owner
  } do
    {:ok, _} = Members.create(%{email: "a@x.io"})
    {:ok, _} = Members.create(%{email: "b@x.io", subscribed: false})
    {:ok, _} = Members.create(%{email: "p@x.io", status: "paid"})

    post =
      post_fixture(owner, %{title: "News!", markdown: "Hello **world**\n\n{{widget counter}}"})

    assert {:ok, 2} = Newsletter.send_post(post)
    assert_email_sent(subject: "News!", to: {"", "a@x.io"})
    assert_email_sent(subject: "News!", to: {"", "p@x.io"})
    refute_email_sent(to: {"", "b@x.io"})
    assert {:error, :already_sent} = Newsletter.send_post(post)
    assert Newsletter.send_record(post)["recipients"] == 2

    paid_post = post_fixture(owner, %{title: "Paid news", visibility: "paid"})
    assert {:ok, 1} = Newsletter.send_post(paid_post)
    assert_email_sent(subject: "Paid news", to: {"", "p@x.io"})

    # the editor button
    draft = post_fixture(owner, %{title: "From the editor"})
    {:ok, view, html} = live(log_in(conn, owner), ~p"/admin/posts/#{draft["id"]}")
    assert html =~ "Send"
    view |> element("button[phx-click=send-newsletter]") |> render_click()
    assert render(view) =~ "sent to 2"
    assert_email_sent(subject: "From the editor")
  end

  test "stripe: checkout needs config; webhook verifies signature and flips the member", %{
    conn: conn
  } do
    {:ok, m} = Members.create(%{email: "pay@x.io"})
    refute Billing.configured?()

    assert {:error, "Stripe is not configured"} =
             Billing.checkout_url(m, "http://x/ok", "http://x/no")

    {:ok, _} =
      Settings.update(%{
        stripe_secret_key: "sk_test_1",
        stripe_webhook_secret: "whsec_test",
        stripe_price_id: "price_1"
      })

    assert Billing.configured?()

    conn_m = log_in_member(conn, m)
    conn_up = get(conn_m, ~p"/members/upgrade")
    assert redirected_to(conn_up) == "https://checkout.stripe.test/session_fake"

    assert_received {:stripe_post, "/v1/checkout/sessions",
                     %{
                       "client_reference_id" => _,
                       "line_items[0][price]" => "price_1",
                       "customer_email" => "pay@x.io"
                     }}

    body =
      Jason.encode!(%{
        type: "checkout.session.completed",
        data: %{
          object: %{customer: "cus_1", subscription: "sub_1", metadata: %{member_id: m["id"]}}
        }
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", "t=1,v1=bad")
      |> post(~p"/webhooks/stripe", body)

    assert conn.status == 400

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", Billing.sign_for_test(body, "whsec_test"))
      |> post(~p"/webhooks/stripe", body)

    assert json_response(conn, 200) == %{"received" => "checkout.session.completed"}
    assert Members.get(m["id"])["status"] == "paid"
    assert Members.get_by_stripe_customer("cus_1")["id"] == m["id"]

    body =
      Jason.encode!(%{
        type: "customer.subscription.deleted",
        data: %{object: %{id: "sub_1", customer: "cus_1", status: "canceled"}}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", Billing.sign_for_test(body, "whsec_test"))
      |> post(~p"/webhooks/stripe", body)

    assert conn.status == 200
    assert Members.get(m["id"])["status"] == "free"
  end

  test "comments: members comment and reply, live for other readers, moderation", %{
    conn: conn,
    owner: owner
  } do
    {:ok, _} = Settings.update(%{comments_enabled: true})
    post = post_fixture(owner, %{title: "Talk"})
    {:ok, m1} = Members.create(%{email: "one@x.io", name: "One"})
    {:ok, m2} = Members.create(%{email: "two@x.io", name: "Two"})

    {:ok, anon, html} = live(conn, ~p"/#{post["slug"]}")
    assert html =~ "Sign in</a> to join the conversation"

    {:ok, v1, _} = live(log_in_member(conn, m1), ~p"/#{post["slug"]}")
    v1 |> form("#comment-form", %{body: "First!"}) |> render_submit()
    assert render(v1) =~ "First!"
    assert render(anon) =~ "First!", "other readers see it live"
    [%{comment: c}] = Wraith.Comments.for_post(post["id"])

    {:ok, v2, _} = live(log_in_member(conn, m2), ~p"/#{post["slug"]}")
    v2 |> element(~s(#comment-#{c["id"]} button[phx-click=reply-to])) |> render_click()

    v2
    |> form("#reply-form-#{c["id"]}", %{body: "Second.", parent_id: c["id"]})
    |> render_submit()

    assert render(anon) =~ "Second."
    assert Wraith.Comments.count(post["id"]) == 2
    [%{replies: [reply]}] = Wraith.Comments.for_post(post["id"])

    assert {:error, "replies go one level deep"} =
             Wraith.Comments.create(post, m1, "nested", reply["id"])

    # m2 may not remove m1's comment; m1 may
    # (the reply's own Remove button sits inside the parent's div: pick the parent's actions row)
    refute has_element?(
             v2,
             ~s(#comment-#{c["id"]} > .comment-actions button[phx-click=comment-delete])
           )

    render_click(
      element(v1, ~s(#comment-#{c["id"]} > .comment-actions button[phx-click=comment-delete]))
    )

    # a removed parent keeps the slot for its reply
    assert [%{comment: %{"body" => ""}, replies: [_]}] = Wraith.Comments.for_post(post["id"])

    # moderation
    {:ok, admin, html} = live(log_in(conn, owner), ~p"/admin/comments")
    assert html =~ "Second."
    admin |> element(~s(#comment-#{reply["id"]} button[phx-click=hide])) |> render_click()
    assert Wraith.Comments.for_post(post["id"]) |> hd() |> Map.get(:replies) == []
    refute render(anon) =~ "Second."
  end

  test "public preview above the paywall; members see everything", %{conn: conn, owner: owner} do
    post =
      post_fixture(owner, %{
        title: "Teaser",
        visibility: "members",
        markdown: "Free intro.\n\n<!--members-only-->\n\nThe secret part."
      })

    {:ok, _, html} = live(conn, ~p"/#{post["slug"]}")
    assert html =~ "Free intro." and html =~ "for members"
    refute html =~ "The secret part."
    {:ok, m} = Members.create(%{email: "p@x.io"})
    {:ok, _, html} = live(log_in_member(conn, m), ~p"/#{post["slug"]}")
    assert html =~ "Free intro." and html =~ "The secret part."
    refute html =~ "members-only", "the marker never renders"
  end

  test "send-on-publish, scheduled unpublish, test mail, word count", %{owner: owner} do
    {:ok, _} = Members.create(%{email: "s@x.io"})

    {:ok, p} =
      Content.create_post(%{
        title: "Auto",
        markdown: "one two three",
        author_id: owner["id"],
        send_on_publish: true,
        unpublish_at: "2000-01-01T00:00:00Z"
      })

    assert Content.word_count(p["markdown"]) == 3
    {:ok, p} = Content.publish_and_send(p)
    assert p["status"] == "published"
    assert_email_sent(subject: "Auto")
    # the clock pulls it back because unpublish_at has passed
    assert Content.publish_due() == 1
    assert Content.get_post(p["id"])["status"] == "draft"

    Newsletter.send_test(p, owner)
    assert_email_sent(subject: "[Test] Auto", to: {owner["name"], owner["email"]})
  end

  test "billing portal, reply notifications, csv, self-deletion", %{conn: conn, owner: owner} do
    {:ok, _} =
      Settings.update(%{
        stripe_secret_key: "sk_test_1",
        stripe_webhook_secret: "whsec_test",
        stripe_price_id: "price_1",
        comments_enabled: true
      })

    {:ok, m} = Members.create(%{email: "pay@x.io", name: "Payer"})

    assert redirected_to(get(log_in_member(conn, m), ~p"/members/portal")) == ~p"/members",
           "no customer yet"

    {:ok, m} = Members.update(m, %{stripe_customer_id: "cus_9"})

    assert redirected_to(get(log_in_member(conn, m), ~p"/members/portal")) ==
             "https://checkout.stripe.test/session_fake"

    assert_received {:stripe_post, "/v1/billing_portal/sessions", %{"customer" => "cus_9"}}

    # a reply mails the parent's author
    post = post_fixture(owner, %{title: "Thread"})
    {:ok, other} = Members.create(%{email: "o@x.io", name: "Other"})
    {:ok, c} = Wraith.Comments.create(post, m, "Parent")
    {:ok, _} = Wraith.Comments.create(post, other, "Child", c["id"])

    assert_email_sent(fn e ->
      assert e.subject =~ "Other replied to your comment"
      assert {"Payer", "pay@x.io"} in e.to
      true
    end)

    {:ok, _} = Wraith.Comments.create(post, m, "Self reply", c["id"])
    refute_email_sent()

    csv = Members.to_csv()
    assert csv =~ "email,name,status" and csv =~ "pay@x.io,Payer,free,true"
    assert Members.from_csv("email,name,status\nnew@x.io,New,paid\npay@x.io,Dup,free") == 1
    assert Members.get_by_email("new@x.io")["status"] == "paid"

    # self-deletion takes the comments along
    conn_m = log_in_member(conn, m)
    conn_d = post(conn_m, ~p"/members/delete")
    assert redirected_to(conn_d) == ~p"/"
    assert Members.get_by_email("pay@x.io") == nil

    refute Wraith.Comments.for_post(post["id"], include_hidden: true)
           |> Enum.flat_map(&[&1.comment | &1.replies])
           |> Enum.any?(&(&1["member_id"] == m["id"] and &1["body"] != ""))
  end
end
