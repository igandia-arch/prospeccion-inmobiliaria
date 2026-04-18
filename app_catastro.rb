require 'sinatra'
require 'net/http'
require 'uri'
require 'json'
require 'csv'
require 'openssl'

set :bind, '0.0.0.0'
set :port, ENV['PORT'] || 4567

get '/' do
  erb :index
end

post '/buscar' do
  @nombre_calle = params[:calle]
  @filtros = {
    min_m2: params[:min_m2].to_i,
    max_m2: params[:max_m2].empty? ? 999999 : params[:max_m2].to_i,
    uso: params[:uso],
    clase: params[:clase],
    min_year: params[:min_year].to_i,
    max_year: params[:max_year].empty? ? Time.now.year : params[:max_year].to_i,
    minuscula: params[:minuscula]
  }

  @resultados = ejecutar_busqueda_web(@nombre_calle, @filtros)
  erb :resultados
end

def ejecutar_busqueda_web(calle, f)
  candidatos = []
  
  url_mapa = URI("https://nominatim.openstreetmap.org/search?q=#{URI.encode_www_form_component(calle + ', Madrid, España')}&format=json")
  res_mapa = Net::HTTP.start(url_mapa.hostname, url_mapa.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE) do |h| 
    h.request(Net::HTTP::Get.new(url_mapa, {'User-Agent' => 'IvanAppWeb'}))
  end
  datos_mapa = JSON.parse(res_mapa.body)
  
  if datos_mapa.empty?
    puts "CHIVATO -> El mapa no ha encontrado la calle."
    return [] 
  end

  bbox = datos_mapa.first["boundingbox"]
  c_lat = (bbox[0].to_f + bbox[1].to_f) / 2.0
  c_lon = (bbox[2].to_f + bbox[3].to_f) / 2.0
  bbox_c = "#{c_lat-0.002},#{c_lon-0.002},#{c_lat+0.002},#{c_lon+0.002}"

  url_wfs = URI("http://ovc.catastro.meh.es/INSPIRE/wfsBU.aspx?service=WFS&version=2.0.0&request=GetFeature&typenames=bu:BuildingPart&srsname=EPSG:4326&BBOX=#{bbox_c}")
  res_wfs = Net::HTTP.get_response(url_wfs)
  xml_wfs = res_wfs.body.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
  
  # --- INICIO DE LOS CHIVATOS ---
  puts "\n========== REPORTE DEL CATASRO =========="
  puts "URL de Búsqueda: #{url_wfs}"
  puts "Código de Respuesta del Gobierno: #{res_wfs.code}"
  puts "Primeros 300 caracteres de lo que nos envían:"
  puts xml_wfs[0..300]
  puts "==========================================\n"
  # --- FIN DE LOS CHIVATOS ---

  refs = xml_wfs.scan(/localId[^>]*>([A-Z0-9]{14})/).flatten.uniq
  puts "CHIVATO -> Edificios extraídos de ese texto: #{refs.count}\n"

  refs.each do |rc14|
    sleep(0.1)
    url_det = URI("http://ovc.catastro.meh.es/ovcservweb/OVCSWLocalizacionRC/OVCCallejero.asmx/Consulta_DNPRC?Provincia=MADRID&Municipio=MADRID&RC=#{rc14}")
    res_det = Net::HTTP.get_response(url_det)
    next unless res_det.is_a?(Net::HTTPSuccess)
    
    xml = res_det.body.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
    
    xml.scan(/<bico>(.*?)<\/bico>/im).each do |prop|
      p_xml = prop[0]
      sfc = p_xml.match(/<sfc>(\d+)<\/sfc>/i) ? $1.to_i : 0
      uso = p_xml.match(/<uso>([^<]+)<\/uso>/i) ? $1.strip : ""
      cn = p_