{
  config,
  lib,
  pkgs,
  ...
}: let
  # Get WAN interface name from config
  wanInterface = config.router.interfaces.wan;
  
  # Function to read JSON file with optional placeholder replacement
  readJsonFile = file: needsReplacement: let
    content = builtins.readFile file;
    processed = if needsReplacement 
      then builtins.replaceStrings ["{{WAN_INTERFACE}}"] [wanInterface] content
      else content;
  in
    builtins.fromJSON processed;

  # Read base dashboard
  baseDashboard = readJsonFile ./parts/base.json false;

  # Define panel sections configuration
  panelSections = [
    {
      title = "System Overview";
      id = 100;
      file = ./parts/system-panels.json;
      panelsPerRow = 4;
      needsReplacement = false;
    }
    {
      title = "Network Interfaces";
      id = 101;
      file = ./parts/network-interfaces-panels.json;
      panelsPerRow = 2;
      needsReplacement = true;
    }
    {
      title = "Client Traffic";
      id = 102;
      file = ./parts/clients-panels.json;
      panelsPerRow = 2;
      needsReplacement = false;
    }
    {
      title = "DNS";
      id = 103;
      file = ./parts/dns-panels.json;
      panelsPerRow = 3;
      needsReplacement = false;
    }
    {
      title = "QoS / Traffic Shaping";
      id = 104;
      file = ./parts/qos-panels.json;
      panelsPerRow = 3;
      needsReplacement = false;
    }
    {
      title = "NAT-PMP Server";
      id = 106;
      file = ./parts/natpmp-panels.json;
      panelsPerRow = 3;
      needsReplacement = false;
    }
    {
      title = "Internet Speed Test";
      id = 107;
      file = ./parts/speedtest-panels.json;
      panelsPerRow = 2;
      needsReplacement = false;
    }
    {
      title = "Network Statistics";
      id = 108;
      file = ./parts/uncategorized-panels.json;
      panelsPerRow = 2;
      needsReplacement = false;
      optional = true;
    }
  ];

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

  # Helper to organize panels in a grid layout
  organizePanelsInGrid = startY: panelsPerRow: panels: let
    panelWidth = 24 / panelsPerRow;
    panelHeight = 8;
  in
    lib.imap0 (i: panel: 
      panel // {
        gridPos = {
          h = panelHeight;
          w = panelWidth;
          x = (lib.mod i panelsPerRow) * panelWidth;
          y = startY + (i / panelsPerRow) * panelHeight;
        };
      }
    ) panels;

  # Calculate the height of a panel section
  sectionHeight = panels:
    if panels == []
    then 1
    else lib.foldl' lib.max 0 (map (panel: 
      (panel.gridPos.y or 0) + (panel.gridPos.h or 8)
    ) panels);

  # Build dashboard sections dynamically
  buildSections = let
    # Process each section and accumulate Y position
    processSections = sections: currentY: processedSections:
      if sections == []
      then processedSections
      else let
        section = builtins.head sections;
        remainingSections = builtins.tail sections;
        
        # Read panels for this section
        panels = (readJsonFile section.file section.needsReplacement).panels;
        
        # Skip optional empty sections
        skipSection = section.optional or false && panels == [];
        
        # Create row and positioned panels
        row = createRow {
          inherit (section) title id;
          y = currentY;
        };
        
        positionedPanels = if skipSection 
          then []
          else organizePanelsInGrid (currentY + 1) section.panelsPerRow panels;
        
        # Calculate next Y position
        nextY = if skipSection
          then currentY
          else currentY + sectionHeight positionedPanels + 2;
        
        # Accumulate results
        newProcessed = if skipSection
          then processedSections
          else processedSections ++ [row] ++ positionedPanels;
      in
        processSections remainingSections nextY newProcessed;
  in
    processSections panelSections 0 [];
in
  # Combine base dashboard with organized panels
  baseDashboard
  // {
    panels = buildSections;
  }