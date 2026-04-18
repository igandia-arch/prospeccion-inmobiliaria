require 'sinatra'
require 'net/http'
require 'uri'
require 'json'
require 'csv'
require 'openssl'

# --- CONFIGURACIÓN PARA LA NUBE ---
set :bind, '0.0.0.0'
set :port, ENV['PORT'] || 4567

# --- PÁGINA PRINCIPAL (EL FORMULARIO) ---
get '/' do
  erb :index
end

# --- PROCESAMIENTO DE LA BÚSQUEDA ---
post '/buscar' do
  @nombre_calle = params[:calle]
  @filtros = {
    min_m2: params[:min_m2].to_i,
    max_m2: params[:max_m2].empty? ? 999999 : params[:max_m2].to_i,
    uso: params[:uso],
    clase: params[:clase],
    min_year: params[:min_year].to_i,
    max_year: params[:max_year].empty? ? Time.now.year : params[:max_year].to_i,
    minuscula: params[:minuscula] # "on" o nil
  }

  @resultados = ejecutar_busqueda_web(@nombre_calle, @filtros)
  erb :resultados
end

# --- LÓGICA DE BÚSQUEDA ---
def ejecutar_busqueda_web(calle, f)
  candidatos = []
  
  url_mapa = URI("https://nominatim.openstreetmap.org/search?q=#{URI.encode_www_form_component(calle + ', Madrid, España')}&format=json")
  res_mapa = Net::HTTP.start(url_mapa.hostname, url_mapa.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE) do |h| 
    h.request(Net::HTTP::Get.new(url_mapa, {'User-Agent' => 'IvanAppWeb'}))
  end
  datos_mapa = JSON.parse(res_mapa.body)
  return [] if datos_mapa.empty?

  bbox = datos_mapa.first["boundingbox"]
  c_lat = (bbox[0].to_f + bbox[1].to_f) / 2.0
  c_lon = (bbox[2].to_f + bbox[3].to_f) / 2.0
  bbox_c = "#{c_lat-0.002},#{c_lon-0.002},#{c_lat+0.002},#{c_lon+0.002}"

  url_wfs = URI("http://ovc.catastro.meh.es/INSPIRE/wfsBU.aspx?service=WFS&version=2.0.0&request=GetFeature&typenames=bu:BuildingPart&srsname=EPSG:4326&BBOX=#{bbox_c}")
  res_wfs = Net::HTTP.get_response(url_wfs)
  
  # MODIFICACIÓN ANTI-ERRORES: Si