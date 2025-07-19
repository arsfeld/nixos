{
  lib,
  pkgs,
  ...
}: let
  # Read all dashboard parts
  baseDashboard = builtins.fromJSON (builtins.readFile ./parts/base.json);

  # Panel categories
  systemPanels = (builtins.fromJSON (builtins.readFile ./parts/system-panels.json)).panels;
  networkInterfacePanels = (builtins.fromJSON (builtins.readFile ./parts/network-interfaces-panels.json)).panels;
  clientPanels = (builtins.fromJSON (builtins.readFile ./parts/clients-panels.json)).panels;
  dnsPanels = (builtins.fromJSON (builtins.readFile ./parts/dns-panels.json)).panels;
  qosPanels = (builtins.fromJSON (builtins.readFile ./parts/qos-panels.json)).panels;
  natpmpPanels = (builtins.fromJSON (builtins.readFile ./parts/natpmp-panels.json)).panels;
  speedtestPanels = (builtins.fromJSON (builtins.readFile ./parts/speedtest-panels.json)).panels;
  uncategorizedPanels = (builtins.fromJSON (builtins.readFile ./parts/uncategorized-panels.json)).panels;

  # Helper to create a row/section header
  createRow = {
    title,
    y,
    id,
    collapsed ? false,
  }: {
    collapsed = collapsed;
    datasource = "Prometheus";
    gridPos = {
      h = 1;
      w = 24;
      x = 0;
      y = y;
    };
    id = id;
    panels = [];
    title = title;
    type = "row";
  };

  # Helper to reposition panels starting at a specific Y position
  repositionPanels = startY: panels: let
    # Calculate cumulative Y positions based on panel heights
    calculatePositions = panels: currentY:
      if panels == []
      then []
      else let
        panel = builtins.head panels;
        remainingPanels = builtins.tail panels;

        # Update panel with new Y position
        updatedPanel =
          panel
          // {
            gridPos = panel.gridPos // {y = currentY;};
          };

        # Calculate next Y position (current Y + panel height)
        nextY = currentY + (panel.gridPos.h or 8);

        # Check if we need to start a new row based on X position
        needsNewRow = (panel.gridPos.x or 0) == 0 && remainingPanels != [];
        actualNextY =
          if needsNewRow
          then nextY
          else currentY;
      in
        [updatedPanel] ++ calculatePositions remainingPanels actualNextY;
  in
    calculatePositions panels startY;

  # Helper to organize panels in a grid layout
  organizePanelsInGrid = startY: panelsPerRow: panels: let
    # Standard panel dimensions
    panelWidth = 24 / panelsPerRow;
    panelHeight = 8;

    # Arrange panels in grid
    arrangePanels = panels: row: col:
      if panels == []
      then []
      else let
        panel = builtins.head panels;
        remainingPanels = builtins.tail panels;

        # Calculate position
        x = col * panelWidth;
        y = startY + (row * panelHeight);

        # Update panel position
        updatedPanel =
          panel
          // {
            gridPos = {
              h = panelHeight;
              w = panelWidth;
              x = x;
              y = y;
            };
          };

        # Calculate next position
        nextCol =
          if col + 1 >= panelsPerRow
          then 0
          else col + 1;
        nextRow =
          if col + 1 >= panelsPerRow
          then row + 1
          else row;
      in
        [updatedPanel] ++ arrangePanels remainingPanels nextRow nextCol;
  in
    arrangePanels panels 0 0;

  # Calculate the height of a panel section
  sectionHeight = panels:
    if panels == []
    then 1
    else let
      maxY =
        lib.foldl' (
          max: panel: let
            panelBottom = (panel.gridPos.y or 0) + (panel.gridPos.h or 8);
          in
            if panelBottom > max
            then panelBottom
            else max
        )
        0
        panels;
    in
      maxY;

  # Build dashboard sections with proper spacing
  buildSections = let
    currentY = 0;

    # System Overview Section
    systemRow = createRow {
      title = "System Overview";
      y = currentY;
      id = 100;
    };
    systemPanelsRepositioned = organizePanelsInGrid (currentY + 1) 4 systemPanels;
    systemSectionHeight = sectionHeight systemPanelsRepositioned + 2;

    # Network Interfaces Section
    networkY = currentY + systemSectionHeight;
    networkRow = createRow {
      title = "Network Interfaces";
      y = networkY;
      id = 101;
    };
    networkPanelsRepositioned = organizePanelsInGrid (networkY + 1) 2 networkInterfacePanels;
    networkSectionHeight = sectionHeight networkPanelsRepositioned + 2;

    # Client Traffic Section
    clientY = networkY + networkSectionHeight;
    clientRow = createRow {
      title = "Client Traffic";
      y = clientY;
      id = 102;
    };
    clientPanelsRepositioned = organizePanelsInGrid (clientY + 1) 2 clientPanels;
    clientSectionHeight = sectionHeight clientPanelsRepositioned + 2;

    # DNS Section
    dnsY = clientY + clientSectionHeight;
    dnsRow = createRow {
      title = "DNS";
      y = dnsY;
      id = 103;
    };
    dnsPanelsRepositioned = organizePanelsInGrid (dnsY + 1) 3 dnsPanels;
    dnsSectionHeight = sectionHeight dnsPanelsRepositioned + 2;

    # QoS/Traffic Shaping Section
    qosY = dnsY + dnsSectionHeight;
    qosRow = createRow {
      title = "QoS / Traffic Shaping";
      y = qosY;
      id = 104;
    };
    qosPanelsRepositioned = organizePanelsInGrid (qosY + 1) 3 qosPanels;
    qosSectionHeight = sectionHeight qosPanelsRepositioned + 2;

    # NAT-PMP Section
    natpmpY = qosY + qosSectionHeight;
    natpmpRow = createRow {
      title = "NAT-PMP Server";
      y = natpmpY;
      id = 106;
    };
    natpmpPanelsRepositioned = repositionPanels (natpmpY + 1) natpmpPanels;
    natpmpSectionHeight = sectionHeight natpmpPanelsRepositioned + 2;

    # Internet Speed Test Section
    speedY = natpmpY + natpmpSectionHeight;
    speedRow = createRow {
      title = "Internet Speed Test";
      y = speedY;
      id = 107;
    };
    speedPanelsRepositioned = organizePanelsInGrid (speedY + 1) 2 speedtestPanels;
    speedSectionHeight = sectionHeight speedPanelsRepositioned + 2;

    # Other Metrics Section (if any uncategorized panels exist)
    otherY = speedY + speedSectionHeight;
    otherRow = createRow {
      title = "Other Metrics";
      y = otherY;
      id = 108;
    };
    otherPanelsRepositioned =
      if uncategorizedPanels != []
      then organizePanelsInGrid (otherY + 1) 3 uncategorizedPanels
      else [];
  in
    # Combine all sections
    [systemRow]
    ++ systemPanelsRepositioned
    ++ [networkRow]
    ++ networkPanelsRepositioned
    ++ [clientRow]
    ++ clientPanelsRepositioned
    ++ [dnsRow]
    ++ dnsPanelsRepositioned
    ++ [qosRow]
    ++ qosPanelsRepositioned
    ++ [natpmpRow]
    ++ natpmpPanelsRepositioned
    ++ [speedRow]
    ++ speedPanelsRepositioned
    ++ (
      if uncategorizedPanels != []
      then [otherRow] ++ otherPanelsRepositioned
      else []
    );
in
  # Combine base dashboard with organized panels
  baseDashboard
  // {
    panels = buildSections;
  }
