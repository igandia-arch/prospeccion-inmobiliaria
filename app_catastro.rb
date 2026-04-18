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
  
  lat_min = (c_lat - 0.002).round(6)
  lon_min = (c_lon - 0.002).round(6)
  lat_max = (c_lat + 0.002).round(6)
  lon_max = (c_lon + 0.002).round(6)
  bbox_c = "#{lat_min},#{lon_min},#{lat_max},#{lon_max}"

  url_wfs = URI("https://ovc.catastro.meh.es/INSPIRE/wfsBU.aspx?service=WFS&version=2.0.0&request=GetFeature&typenames=bu:BuildingPart&srsname=EPSG:4326&BBOX=#{bbox_c}")
  
  req_wfs = Net::HTTP::Get.new(url_wfs)
  req_wfs['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
  res_wfs = Net::HTTP.start(url_wfs.hostname, url_wfs.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE) { |h| h.request(req_wfs) }
  
  xml_wfs = res_wfs.body.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
  refs = xml_wfs.scan(/localId[^>]*>([A-Z0-9]{14})/).flatten.uniq

  refs.each do |rc14|
    sleep(0.1)
    
    url_det = URI("https://ovc.catastro.meh.es/ovcservweb/OVCSWLocalizacionRC/OVCCallejero.asmx/Consulta_DNPRC?Provincia=MADRID&Municipio=MADRID&RC=#{rc14}")
    req_det = Net::HTTP::Get.new(url_det)
    req_det['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    res_det = Net::HTTP.start(url_det.hostname, url_det.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE) { |h| h.request(req_det) }
    
    next unless res_det.is_a?(Net::HTTPSuccess)
    
    xml = res_det.body.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
    
    xml.scan(/<bico>(.*?)<\/bico>/im).each do |prop|
      p_xml = prop[0]
      sfc = p_xml.match(/<sfc>(\d+)<\/sfc>/i) ? $1.to_i : 0
      uso = p_xml.match(/<uso>([^<]+)<\/uso>/i) ? $1.strip : ""
      cn = p_xml.match(/<cn>([^<]+)<\/cn>/i) ? $1.strip : ""
      ant = p_xml.match(/<ant>(\d+)<\/ant>/i) ? $1.to_i : 0
      pt = p_xml.match(/<pt>([^<]*)<\/pt>/i) ? $1.strip : ""
      pu = p_xml.match(/<pu>([^<]*)<\/pu>/i) ? $1.strip : ""
      
      dir = p_xml.match(/<ldt>([^<]+)<\/ldt>/i) ? $1.strip : "Sin dirección"

      next if sfc < f[:min_m2] || sfc > f[:max_m2]
      next if f[:uso] != "*" && uso != f[:uso]
      next if f[:clase] != "*" && cn != f[:clase]
      next if ant < f[:min_year] || ant > f[:max_year]
      if f[:minuscula] == "on"
        next unless (pt.match?(/[a-z]/) || pu.match?(/[a-z]/))
      end

      candidatos << { dir: dir, sfc: sfc, uso: uso, ant: ant, pt: pt, pu: pu, rc: rc14 }
    end
  end
  candidatos
end

__END__

@@index
<!DOCTYPE html>
<html>
<head>
  <title>Prospección Madrid</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/water.css@2/out/water.css">
  <style>
    /* El diseño del reloj dando vueltas */
    .spinner {
      border: 5px solid rgba(0, 0, 0, 0.1);
      width: 40px;
      height: 40px;
      border-radius: 50%;
      border-left-color: #007BFF;
      animation: spin 1s linear infinite;
      margin: 0 auto 15px auto;
    }
    @keyframes spin {
      0% { transform: rotate(0deg); }
      100% { transform: rotate(360deg); }
    }
    
    /* La animación de los puntitos suspensivos */
    .loading-text:after {
      content: '.';
      animation: dots 1.5s steps(5, end) infinite;
    }
    @keyframes dots {
      0%, 20% { color: rgba(0,0,0,0); text-shadow: .25em 0 0 rgba(0,0,0,0), .5em 0 0 rgba(0,0,0,0); }
      40% { color: #007BFF; text-shadow: .25em 0 0 rgba(0,0,0,0), .5em 0 0 rgba(0,0,0,0); }
      60% { text-shadow: .25em 0 0 #007BFF, .5em 0 0 rgba(0,0,0,0); }
      80%, 100% { text-shadow: .25em 0 0 #007BFF, .5em 0 0 #007BFF; }
    }
  </style>
  <script>
    function mostrarCarga() {
      document.getElementById('cargando').style.display = 'block';
      document.getElementById('btn-buscar').style.display = 'none';
    }
  </script>
</head>
<body>
  <h1>🏙️ Prospección Inmobiliaria</h1>
  <form action="/buscar" method="POST" onsubmit="mostrarCarga()">
    <label>📍 Calle o Zona (Madrid):</label>
    <input type="text" name="calle" placeholder="Ej: Alcalá 100" required>
    
    <div style="display:flex; gap:10px;">
      <div><label>Mín m2:</label><input type="number" name="min_m2" value="0"></div>
      <div><label>Máx m2:</label><input type="number" name="max_m2"></div>
    </div>

    <label>🏢 Uso Principal:</label>
    <select name="uso">
      <option value="*">Todos los usos</option>
      <option value="C">Comercial</option>
      <option value="I">Industrial</option>
      <option value="O">Oficinas</option>
      <option value="V">Residencial</option>
      <option value="A">Almacén</option>
    </select>

    <label>🧱 Clase de Inmueble:</label>
    <select name="clase">
      <option value="UR">Urbano (Madrid Ciudad)</option>
      <option value="RU">Rústico</option>
      <option value="*">Cualquier clase</option>
    </select>

    <div style="display:flex; gap:10px;">
      <div><label>Desde año:</label><input type="number" name="min_year" value="0"></div>
      <div><label>Hasta año:</label><input type="number" name="max_year"></div>
    </div>

    <label>
      <input type="checkbox" name="minuscula"> Solo letras minúsculas (bj, iz...)
    </label>
    <br><br>
    
    <button type="submit" id="btn-buscar">🚀 Iniciar Prospección</button>
    
    <div id="cargando" style="display:none; text-align:center; margin-top:20px;">
      <div class="spinner"></div>
      <h3 style="color:#007BFF; display:inline-block;">Estoy pensando, no me estoy rascando las narices. Espera, plis<span class="loading-text"></span></h3>
      <p style="color:#666;"><small>(Buceando en el Catastro. Esto puede tardar hasta 1 minuto...)</small></p>
    </div>
  </form>
</body>
</html>

@@resultados
<!DOCTYPE html>
<html>
<head>
  <title>Resultados</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/water.css@2/out/water.css">
  <script>
    function descargarExcel() {
      var csv = [];
      var rows = document.querySelectorAll("table tr");
      for (var i = 0; i < rows.length; i++) {
        var row = [], cols = rows[i].querySelectorAll("td, th");
        for (var j = 0; j < cols.length; j++) {
            row.push('"' + cols[j].innerText.replace(/"/g, '""') + '"');
        }
        csv.push(row.join(";"));
      }
      var csvFile = new Blob(["\uFEFF" + csv.join("\n")], {type: "text/csv;charset=utf-8;"});
      var downloadLink = document.createElement("a");
      downloadLink.download = "prospeccion_<%= @nombre_calle.gsub(' ', '_') %>.csv";
      downloadLink.href = window.URL.createObjectURL(csvFile);
      downloadLink.style.display = "none";
      document.body.appendChild(downloadLink);
      downloadLink.click();
    }
  </script>
</head>
<body>
  <div style="display:flex; justify-content:space-between; align-items:center;">
    <a href="/">⬅️ Nueva Búsqueda</a>
    <button onclick="descargarExcel()" style="background-color:#28a745; color:white; border-radius:5px;">📥 Descargar Excel</button>
  </div>
  
  <h1>📍 Resultados: <%= @nombre_calle %></h1>
  <p>Se han encontrado <strong><%= @resultados.count %></strong> propiedades.</p>

  <table border="1" style="width:100%; text-align:left;">
    <thead>
      <tr>
        <th>Dirección Exacta</th>
        <th>m2</th>
        <th>Uso</th>
        <th>Año</th>
        <th>Planta/Pta</th>
        <th>Ref. Catastral</th>
      </tr>
    </thead>
    <tbody>
      <% @resultados.each do |r| %>
        <tr>
          <td><%= r[:dir] %></td>
          <td><%= r[:sfc] %></td>
          <td><%= r[:uso] %></td>
          <td><%= r[:ant] %></td>
          <td><%= r[:pt] %> <%= r[:pu] %></td>
          <td><code><%= r[:rc] %></code></td>
        </tr>
      <% end %>
    </tbody>
  </table>
</body>
</html>
