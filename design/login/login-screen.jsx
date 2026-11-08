/*
 * pabrik — Login screen, replicated 1:1 from
 *   src/apps/desktop/src/views/LoginView.vue   (template + scoped CSS)
 *   src/apps/desktop/src/style.css             (:root Kanagawa Dragon tokens, @theme type scale)
 *
 * Render with the OpenPencil MCP `render` tool. Every colour and size below
 * traces to a token — see the PR body for the token map.
 *
 *   page bg        --semantic-content-bg   #181616
 *   card bg        --semantic-card-bg      #1D1C19
 *   border         --color-border          #282727
 *   text           --semantic-text         #c5c9c5
 *   text muted     --semantic-text-muted   #a6a69c
 *   text dim       --semantic-text-dim     #7a8382
 *   accent         --semantic-accent       #8992a7
 *   error          --semantic-error        #c4746e
 *   input bg       --color-bg-dim          #12120f
 *   disabled bg    --color-bg-p1           #282727
 *
 *   title          --text-title-sm  18px / 600 / -0.01em
 *   label          --text-dense     12px / 500
 *   field text     --text-body      14px
 */

<Frame name="Login — design" w="hug" h="hug" flex="col" gap={64} p={64} bg="#181616">

  {/* ── 1. The screen, 1:1 — default state (empty fields, submit disabled) ── */}
  <Frame name="Login / Desktop 1440×900" w={1440} h={900} flex="col" items="center" justify="center" bg="#181616">
    <Frame name="Login card" w={320} h="hug" flex="col" gap={16} p={24} rounded={12} bg="#1D1C19" stroke="#282727" strokeWidth={1} shadow="0 8 24 #00000052">
      <Text name="Title" size={18} weight={600} letterSpacing={-0.18} color="#c5c9c5">Welcome back</Text>

      <Frame name="Field / Email" w="fill" h="hug" flex="col" gap={6}>
        <Text name="Label" size={12} weight={500} color="#a6a69c">Email</Text>
        <Frame name="Input" w="fill" h={36} flex="row" items="center" px={11} rounded={8} bg="#12120f" stroke="#282727" strokeWidth={1}>
          <Text name="Placeholder" size={14} color="#7a8382">you@example.com</Text>
        </Frame>
      </Frame>

      <Frame name="Field / Password" w="fill" h="hug" flex="col" gap={6}>
        <Text name="Label" size={12} weight={500} color="#a6a69c">Password</Text>
        <Frame name="Input shell" w="fill" h={36} flex="row" items="center" pl={11} pr={4} rounded={8} bg="#12120f" stroke="#282727" strokeWidth={1}>
          <Text name="Placeholder" grow={1} size={14} color="#7a8382">••••••••</Text>
          <Frame name="Reveal button" w={26} h={26} flex="row" items="center" justify="center" rounded={6}>
            <Icon name="lucide:lock" size={15} color="#7a8382" />
          </Frame>
        </Frame>
      </Frame>

      <Frame name="Primary button" w="fill" h={36} flex="row" items="center" justify="center" px={12} rounded={8} bg="#282727">
        <Text name="Label" size={14} weight={600} color="#7a8382">Sign in</Text>
      </Frame>
    </Frame>
  </Frame>

  {/* ── 2. States — the four branches the template can render ── */}
  <Frame name="Login / States" w="hug" h="hug" flex="row" gap={48} items="start">

    {/* Filled — canSubmit true, submit enabled */}
    <Frame name="State=Filled" w="hug" h="hug" flex="col" gap={12}>
      <Text name="Caption" size={12} weight={500} color="#a6a69c">Filled — submit enabled</Text>
      <Frame name="Login card" w={320} h="hug" flex="col" gap={16} p={24} rounded={12} bg="#1D1C19" stroke="#282727" strokeWidth={1} shadow="0 8 24 #00000052">
        <Text name="Title" size={18} weight={600} letterSpacing={-0.18} color="#c5c9c5">Welcome back</Text>
        <Frame name="Field / Email" w="fill" h="hug" flex="col" gap={6}>
          <Text name="Label" size={12} weight={500} color="#a6a69c">Email</Text>
          <Frame name="Input" w="fill" h={36} flex="row" items="center" px={11} rounded={8} bg="#12120f" stroke="#282727" strokeWidth={1}>
            <Text name="Value" size={14} color="#c5c9c5">ginwa@pabrik.dev</Text>
          </Frame>
        </Frame>
        <Frame name="Field / Password" w="fill" h="hug" flex="col" gap={6}>
          <Text name="Label" size={12} weight={500} color="#a6a69c">Password</Text>
          <Frame name="Input shell" w="fill" h={36} flex="row" items="center" pl={11} pr={4} rounded={8} bg="#12120f" stroke="#282727" strokeWidth={1}>
            <Text name="Value" grow={1} size={14} color="#c5c9c5">••••••••••</Text>
            <Frame name="Reveal button" w={26} h={26} flex="row" items="center" justify="center" rounded={6}>
              <Icon name="lucide:lock" size={15} color="#7a8382" />
            </Frame>
          </Frame>
        </Frame>
        <Frame name="Primary button" w="fill" h={36} flex="row" items="center" justify="center" px={12} rounded={8} bg="#8992a7">
          <Text name="Label" size={14} weight={600} color="#12120f">Sign in</Text>
        </Frame>
      </Frame>
    </Frame>

    {/* Error — role="alert" box above the submit */}
    <Frame name="State=Error" w="hug" h="hug" flex="col" gap={12}>
      <Text name="Caption" size={12} weight={500} color="#a6a69c">Error — invalid credentials</Text>
      <Frame name="Login card" w={320} h="hug" flex="col" gap={16} p={24} rounded={12} bg="#1D1C19" stroke="#282727" strokeWidth={1} shadow="0 8 24 #00000052">
        <Text name="Title" size={18} weight={600} letterSpacing={-0.18} color="#c5c9c5">Welcome back</Text>
        <Frame name="Field / Email" w="fill" h="hug" flex="col" gap={6}>
          <Text name="Label" size={12} weight={500} color="#a6a69c">Email</Text>
          <Frame name="Input" w="fill" h={36} flex="row" items="center" px={11} rounded={8} bg="#12120f" stroke="#282727" strokeWidth={1}>
            <Text name="Value" size={14} color="#c5c9c5">ginwa@pabrik.dev</Text>
          </Frame>
        </Frame>
        <Frame name="Field / Password" w="fill" h="hug" flex="col" gap={6}>
          <Text name="Label" size={12} weight={500} color="#a6a69c">Password</Text>
          <Frame name="Input shell" w="fill" h={36} flex="row" items="center" pl={11} pr={4} rounded={8} bg="#12120f" stroke="#282727" strokeWidth={1}>
            <Text name="Value" grow={1} size={14} color="#c5c9c5">••••••••••</Text>
            <Frame name="Reveal button" w={26} h={26} flex="row" items="center" justify="center" rounded={6}>
              <Icon name="lucide:lock" size={15} color="#7a8382" />
            </Frame>
          </Frame>
        </Frame>
        <Frame name="Error" w="fill" h="hug" flex="row" items="center" px={10} py={7} rounded={8} bg="#c4746e1f" stroke="#c4746e59" strokeWidth={1}>
          <Text name="Message" size={12} color="#c4746e">Invalid email or password</Text>
        </Frame>
        <Frame name="Primary button" w="fill" h={36} flex="row" items="center" justify="center" px={12} rounded={8} bg="#8992a7">
          <Text name="Label" size={14} weight={600} color="#12120f">Sign in</Text>
        </Frame>
      </Frame>
    </Frame>

    {/* Busy — inputs disabled at 60%, submit reads "Signing in…" */}
    <Frame name="State=Busy" w="hug" h="hug" flex="col" gap={12}>
      <Text name="Caption" size={12} weight={500} color="#a6a69c">Busy — request in flight</Text>
      <Frame name="Login card" w={320} h="hug" flex="col" gap={16} p={24} rounded={12} bg="#1D1C19" stroke="#282727" strokeWidth={1} shadow="0 8 24 #00000052">
        <Text name="Title" size={18} weight={600} letterSpacing={-0.18} color="#c5c9c5">Welcome back</Text>
        <Frame name="Field / Email" w="fill" h="hug" flex="col" gap={6}>
          <Text name="Label" size={12} weight={500} color="#a6a69c">Email</Text>
          <Frame name="Input" w="fill" h={36} flex="row" items="center" px={11} rounded={8} bg="#12120f" stroke="#282727" strokeWidth={1} opacity={0.6}>
            <Text name="Value" size={14} color="#c5c9c5">ginwa@pabrik.dev</Text>
          </Frame>
        </Frame>
        <Frame name="Field / Password" w="fill" h="hug" flex="col" gap={6}>
          <Text name="Label" size={12} weight={500} color="#a6a69c">Password</Text>
          <Frame name="Input shell" w="fill" h={36} flex="row" items="center" pl={11} pr={4} rounded={8} bg="#12120f" stroke="#282727" strokeWidth={1} opacity={0.6}>
            <Text name="Value" grow={1} size={14} color="#c5c9c5">••••••••••</Text>
            <Frame name="Reveal button" w={26} h={26} flex="row" items="center" justify="center" rounded={6} opacity={0.5}>
              <Icon name="lucide:lock" size={15} color="#7a8382" />
            </Frame>
          </Frame>
        </Frame>
        <Frame name="Primary button" w="fill" h={36} flex="row" items="center" justify="center" px={12} rounded={8} bg="#282727">
          <Text name="Label" size={14} weight={600} color="#7a8382">Signing in…</Text>
        </Frame>
      </Frame>
    </Frame>

    {/* Auth disabled — the muted note branch */}
    <Frame name="State=Auth disabled" w="hug" h="hug" flex="col" gap={12}>
      <Text name="Caption" size={12} weight={500} color="#a6a69c">Auth disabled on this server</Text>
      <Frame name="Login card" w={320} h="hug" flex="col" gap={16} p={24} rounded={12} bg="#1D1C19" stroke="#282727" strokeWidth={1} shadow="0 8 24 #00000052">
        <Text name="Title" size={18} weight={600} letterSpacing={-0.18} color="#c5c9c5">Welcome back</Text>
        <Text name="Muted note" w="fill" size={12} color="#a6a69c">Authentication is disabled on this server.</Text>
        <Frame name="Field / Email" w="fill" h="hug" flex="col" gap={6}>
          <Text name="Label" size={12} weight={500} color="#a6a69c">Email</Text>
          <Frame name="Input" w="fill" h={36} flex="row" items="center" px={11} rounded={8} bg="#12120f" stroke="#282727" strokeWidth={1}>
            <Text name="Placeholder" size={14} color="#7a8382">you@example.com</Text>
          </Frame>
        </Frame>
        <Frame name="Field / Password" w="fill" h="hug" flex="col" gap={6}>
          <Text name="Label" size={12} weight={500} color="#a6a69c">Password</Text>
          <Frame name="Input shell" w="fill" h={36} flex="row" items="center" pl={11} pr={4} rounded={8} bg="#12120f" stroke="#282727" strokeWidth={1}>
            <Text name="Placeholder" grow={1} size={14} color="#7a8382">••••••••</Text>
            <Frame name="Reveal button" w={26} h={26} flex="row" items="center" justify="center" rounded={6}>
              <Icon name="lucide:lock" size={15} color="#7a8382" />
            </Frame>
          </Frame>
        </Frame>
        <Frame name="Primary button" w="fill" h={36} flex="row" items="center" justify="center" px={12} rounded={8} bg="#282727">
          <Text name="Label" size={14} weight={600} color="#7a8382">Sign in</Text>
        </Frame>
      </Frame>
    </Frame>

  </Frame>
</Frame>
