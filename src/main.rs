use actix_web::{post, App, HttpServer, HttpResponse, Responder};
use reqwest::Client;
use serde_json::{from_str, Value};
use url::form_urlencoded;
use std::string::String;
use embryo::{Embryo, EmbryoList};
use chrono::{Duration, Local};
use std::collections::HashMap;

static SEARCH_URL: &str = "https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH";

#[post("/query")]
async fn query_handler(body: String) -> impl Responder {
    let embryo_list = generate_embryo_list(body).await;
    let response = EmbryoList { embryo_list };
    HttpResponse::Ok().json(response)
}

async fn generate_embryo_list(json_search: String) -> Vec<Embryo> {
    let current_date = Local::now().naive_local().date();
    let seven_days_ago = current_date - Duration::days(7);
    let current_date_sql = current_date.format("%Y-%m-%d").to_string();
    let seven_days_ago_sql = seven_days_ago.format("%Y-%m-%d").to_string();

    let search_url = format!("{}?fromDate={}&toDate={}&alertlevel=orange;red&eventlist=&country=", SEARCH_URL, seven_days_ago_sql, current_date_sql);

    println!("{}", search_url);
    let response = Client::new().get(search_url).send().await;

    match response {
        Ok(response) => {
            if let Ok(body) = response.text().await {
                return extract_links_from_results(body, json_search);
            }
        }
        Err(e) => eprintln!("Error fetching search results: {:?}", e),
    }

    Vec::new()
}

fn extract_links_from_results(json_data: String, json_search: String) -> Vec<Embryo> {
    let mut embryo_list = Vec::new();
    let em_search: HashMap<String, String> = from_str(&json_search).expect("Erreur lors de la désérialisation JSON");
    let (_key, value) = em_search.iter().next().expect("Empty map");
    let search: String = form_urlencoded::byte_serialize(value.as_bytes()).collect();
    let parsed_json: Value = serde_json::from_str(&json_data).unwrap();
    
    println!("{}", search);

    if let Some(features) = parsed_json.get("features").and_then(|v| v.as_array()) {
        for feature in features {
            let name = feature["properties"]["name"].as_str().unwrap_or("");
            let url = feature["properties"]["url"]["report"].as_str().unwrap_or("N/A");
            let country = feature["properties"]["country"].as_str().unwrap_or("");
            let fromdate = feature["properties"]["fromdate"].as_str().unwrap_or("");

            if search.contains(name) || name.contains(&search) || search.contains(country) || country.contains(&search) || search.contains(fromdate) || fromdate.contains(&search) {
                let mut embryo_properties = HashMap::new();
                embryo_properties.insert("url".to_string(),url.to_string());
                embryo_properties.insert("resume".to_string(),format!("{} : {} - from {}", name, country, fromdate));
                println!("{:?}", embryo_properties);
                let embryo = Embryo {
                    properties: embryo_properties,
                };
                embryo_list.push(embryo);
            }
        }
    }

    embryo_list
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    match em_filter::find_port().await {
        Some(port) => {
            let filter_url = format!("http://localhost:{}/query", port);
            println!("Filter registrer: {}", filter_url);
            em_filter::register_filter(&filter_url).await;
            HttpServer::new(|| App::new().service(query_handler))
                .bind(format!("127.0.0.1:{}", port))?.run().await?;
        },
        None => {
            println!("Can't start");
        },
    }
    Ok(())
}
