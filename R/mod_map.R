# Module UI

#' @title   mod_map_ui and mod_map_server
#' @description  A shiny Module.
#'
#' @param id shiny id
#' @param input internal
#' @param output internal
#' @param session internal
#'
#' @rdname mod_map
#'
#' @keywords internal
#' @export 
#' @importFrom shiny NS tagList 
mod_map_ui <- function(id){
  ns <- NS(id)
  
  region_selects <- dplyr::bind_rows(
      all_continents,
      dplyr::distinct(sf_world %>% sf::st_set_geometry(NULL), continent, region)
    )
  region_selects <- c("Worldwide", split(region_selects$region, region_selects$continent))
  
  tagList(
    fluidRow(
      col_2(
        selectInput(
          ns("source"), 
          "Data source", 
          choices = c("ECDC", "WHO"),
          width = "100%"
        )
      ),
      col_2(
        selectInput(
          ns("region"), 
          "Region Focus", 
          choices = region_selects, #c("All", "Asia", "Africa", "Europe", "Americas", "Oceania"),
          width = "100%"
        )
      ),
      col_2(
        selectInput(
          ns("indicator"), 
          "Indicator", 
          choices = c("Cases" = "cases", "Deaths" = "deaths"),
          width = "100%"
        )
      ),
      col_2(
        dateRangeInput(
          ns("time_period"),
          label = "Time period",
          min = min(df_ecdc$date, na.rm = TRUE),
          max = Sys.Date(),
          start = min(df_ecdc$date, na.rm = TRUE),
          end = Sys.Date(),
          #timeFormat = "%d/%m/%y",
          #step = 1,
          width = "100%"
        )
      ),
      col_4(
        selectInput(
          ns("intervention"),
          "Interventions",
          choices = c("Highlight national interventions" = "", sort(unique(df_interventions$measure))),
          width = "100%"
        )
      )
    ),
    fluidRow(
      col_12(
        leaflet::leafletOutput(ns("map"))
      ),
      col_12(
        highcharter::highchartOutput(ns("epicurve"), height = 300)
      )
    )
  )
}

# Module Server

#' @rdname mod_map
#' @export
#' @keywords internal
#' @import leaflet
#' @import highcharter
mod_map_server <- function(input, output, session){
  ns <- session$ns
  
  w <- waiter::Waiter$new(
    id = ns("map"),
    html = waiter::spin_3(), 
    color = waiter::transparent(.5)
  )
  
  # Region select observers ====================================================
  
  # selected region is input$region unless user clicks on country on map
  
  # reactive val boolean to indicate if a shape has been selected
  map_click <- reactiveVal(FALSE)
  region_select <- reactiveVal()
  #region_type <- reactiveVal("global")
  
  # if region is selected from map, update map_click value and drop-down selected value
  observeEvent(input$region, {
    region_select(input$region)
    #region_type("region")
  })
  
  # if region is selected from map, update region_select value
  observeEvent(input$map_shape_click$id, {
    map_click(TRUE)
    region_select(input$map_shape_click$id)
    #region_type("country")
  })
  
  observeEvent(input$map_marker_click$id, {
    map_click(TRUE)
    iso <- stringr::str_remove(input$map_marker_click$id, "_mrkr")
    region_select(iso)
    #region_type("country")
  })
  
  observeEvent(input$map_click, {
    if(map_click()) {
      map_click(FALSE)
    } else {
      region_select(input$region)
      #region_type("region")
    }
  })
  
  region_type <- reactive({
    r <- region_select()
    dplyr::case_when(
      r == "Worldwide" ~ "global",
      r %in% continents ~ "continent",
      r %in% world_regions ~ "region",
      TRUE ~ "country"
    )
  })
  
  # Data ========================================================
  
  # switch data source based on user input
  df_data <- reactive({
    switch(
      input$source, 
      ECDC = df_ecdc,
      WHO = df_who
    )
  })
  
  map_interventions <- reactive({
    
    df <- df_interventions %>% 
      dplyr::filter(
        measure == input$intervention, 
        date_implemented >= input$time_period[1],
        date_implemented <= input$time_period[2]
      ) %>% 
      dplyr::group_by(iso, measure) %>% 
      dplyr::filter(date_implemented == max(date_implemented)) %>% 
      dplyr::ungroup() %>% 
      dplyr::left_join(sf_world, by = c("iso" = "iso_a3"), suffix = c("", ".y")) %>% 
      sf::st_as_sf()
    
    if (input$region != "Worldwide") {
      if (input$region %in% continents) {
        df <- df %>% dplyr::filter(continent == input$region)
      } else {
        df <- df %>% dplyr::filter(region == input$region)
      }
    }
    
    return(df)
  })
  
  map_indicators <- reactive({
    
    req(length(input$time_period) == 2)
    
    df <- df_data()
    
    if (input$region != "Worldwide") {
      if (input$region %in% continents) {
        df <- df %>% dplyr::filter(continent == input$region)
      } else {
        df <- df %>% dplyr::filter(region == input$region)
      }
    }
    
    df <- df %>% 
      dplyr::filter(
        date >= input$time_period[1],
        date <= input$time_period[2]
      ) %>% 
      tidyr::drop_na(iso_a3) %>% 
      dplyr::group_by(country, iso_a3) %>% 
      dplyr::summarise(cases = sum(cases, na.rm = TRUE), deaths = sum(deaths, na.rm = TRUE)) %>% 
      dplyr::inner_join(dplyr::select(sf_world, iso_a3, lon, lat), by = c("iso_a3")) %>% 
      sf::st_as_sf()
      
    return(df)
  })
  
  df_epicurve <- reactive({
    
    req(length(input$time_period) == 2)
    
    df <- df_data()
    
    r_type <- region_type()
    
    if (r_type != "global") {
      if (r_type == "continent") {
        df <- df %>% dplyr::filter(continent == region_select())
      } else if (r_type == "region") {
        df <- df %>% dplyr::filter(region == region_select())
      } else if (r_type == "country") {
        df <- df %>% dplyr::filter(iso_a3 == region_select())
      }
    }
    
    df <- df %>% 
      dplyr::filter(
        date >= input$time_period[1],
        date <= input$time_period[2]
      ) %>% 
      dplyr::group_by(date) %>% 
      dplyr::summarise(cases = sum(cases, na.rm = TRUE), deaths = sum(deaths, na.rm = TRUE))
    
    return(df)
  })
  
  # Outputs ========================================================
  
  output$map <- renderLeaflet({
    
    leaflet() %>%
      addMapPane(name = "polygons", zIndex = 410) %>%
      addMapPane(name = "choropleth", zIndex = 410) %>%
      addMapPane(name = "borders", zIndex = 420) %>%
      addMapPane(name = "circles", zIndex = 430) %>%
      addMapPane(name = "place_labels", zIndex = 440) %>%
      addProviderTiles("CartoDB.PositronNoLabels", group = "No Labels") %>%
      addProviderTiles("CartoDB.PositronNoLabels", group = "Labels") %>%
      addProviderTiles("CartoDB.PositronOnlyLabels", group = "Labels", 
                       options = leafletOptions(pane = "place_labels")) %>%
      setView(0, 40, zoom = 2) %>% 
      addScaleBar(position = "bottomleft") %>% 
      addLayersControl(
        baseGroups = c("Labels", "No Labels"),
        overlayGroups = c("Indicators", "Interventions"),
        position = "topleft"
      )
    
  })
  
  observeEvent(map_interventions(), {
    
    if (input$intervention == "" | nrow(map_interventions()) < 1) {
      leafletProxy("map", session) %>%
        clearGroup("Interventions") %>% 
        removeControl(layerId = "choro_legend")
    } else {
      dat <- map_interventions()
      
      popup_cols <- c("country", "measure", "date_implemented", "comments")
      
      #browser()
      
      leafletProxy("map", session) %>%
        clearGroup("Interventions") %>%
        removeControl(layerId = "choro_legend") %>% 
        addPolygons(
          data = dat,
          stroke = TRUE,
          color = "white",
          weight = 1,
          fillColor = "red",
          fillOpacity = .4,
          label = ~country,
          popup = leafpop::popupTable(dat, zcol = popup_cols, row.numbers = FALSE, feature.id = FALSE),
          highlightOptions = highlightOptions(bringToFront = TRUE, fillOpacity = .5),
          group = "Interventions",
          options = pathOptions(pane = "choropleth")
        ) %>% 
        addLegend(
          position = "bottomright",
          title = "Intervention",
          colors = "red",
          labels = isolate(break_text_html(input$intervention)),
          layerId = "choro_legend",
          group = "Interventions"
        )
    }

    w$hide()
  })
  
  observe({
    dat <- map_indicators()
    ind <- dat[[input$indicator]]
    ind_lab <- stringr::str_to_title(input$indicator)
    
    leafletProxy("map", session) %>% 
      clearGroup("Indicators") %>%
      removeControl(layerId = "circle_legend") %>% 
      addPolygons(
        data = dat,
        stroke = FALSE,
        fillOpacity = 0,
        label = ~glue::glue("<b>{country}</b><br>Cases: {cases}<br>Deaths: {deaths}") %>% purrr::map(htmltools::HTML),
        layerId = ~iso_a3,
        group = "Indicators",
        options = pathOptions(pane = "polygons")
      ) %>% 
      addCircleMarkers(
        data = dat, 
        lng = ~lon, 
        lat = ~lat, 
        radius = ~calc_radius(ind), 
        fillColor = "#57AACB", 
        fillOpacity = 0.8, 
        weight = 1, 
        color = "#FFFFFF", 
        opacity = 1, 
        label = ~glue::glue("<b>{country}</b><br>Cases: {cases}<br>Deaths: {deaths}") %>% purrr::map(htmltools::HTML),
        #popup = leafpop::popupTable(dat, zcol = c("country", "cases"), row.numbers = FALSE, feature.id = FALSE),
        layerId = ~paste0(iso_a3, "_mrkr"),
        group = "Indicators",
        options = pathOptions(pane = "circles")
      ) %>% 
      addCircleLegend(
        title = ind_lab,
        range = ind,
        scaling_fun = calc_radius,
        fillColor = "#57AACB", 
        fillOpacity = 0.8, 
        weight = 1, 
        color = "#FFFFFF", 
        position = "topright",
        layerId = "circle_legend",
        group = "Indicators"
      )
    
    w$hide() 
  })
  
  observeEvent(input$region, {
    
    r_type <- region_type()
    
    if (r_type == "global") {
      leafletProxy("map", session) %>% 
        clearGroup("Borders") %>% 
        flyTo(0, 40, zoom = 2)
    } else {
      
      if (r_type == "continent") {
        sf_shps <- sf_world %>% dplyr::filter(continent == isolate(input$region))
      } else {
        sf_shps <- sf_world %>% dplyr::filter(region == isolate(input$region))
      }
      
      bbox <- sf::st_bbox(sf_shps)
      
      leafletProxy("map", session) %>% 
        clearGroup("Borders") %>% 
        addPolylines(
          data = sf_shps, 
          group = "Borders", 
          weight = 1, 
          color = "red", 
          opacity = 1,
          options = pathOptions(pane = "borders")
        ) %>% 
        flyToBounds(bbox[["xmin"]], bbox[["ymin"]], bbox[["xmax"]], bbox[["ymax"]])
    }

  })
  

  output$epicurve <- renderHighchart({
    df <- df_epicurve()
    ind <- rlang::sym(input$indicator)
    
    if (region_type() == "country") {
      title = paste(names(country_iso[country_iso == region_select()]), "daily", input$indicator)
    } else {
      title = paste(region_select(), "daily", input$indicator)
    }
    
    y_lab <- stringr::str_to_title(input$indicator)
    
    hchart(df, type = "column", hcaes(date, !!ind), name = input$indicator) %>% 
      hc_title(text = title) %>% 
      hc_subtitle(text = "Click country on map to filter") %>% 
      hc_xAxis(title = list(text = "")) %>% 
      hc_yAxis(title = list(text = y_lab), allowDecimals = FALSE) %>%
      hc_plotOptions(
        #series = list(stacking = stacking),
        column = list(groupPadding = 0.05, pointPadding = 0.05, borderWidth = 0.05)
      ) %>%
      hc_colors("steelblue") %>% 
      hc_add_theme(hc_theme_smpl())
  })
  
}

## To be copied in the UI
# mod_map_ui("map_1")

## To be copied in the server
# callModule(mod_map_server, "map_1")
