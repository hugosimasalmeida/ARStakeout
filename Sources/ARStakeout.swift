//
//  ARStakeout.swift
//  Verificacao AR de levantamentos GNSS/manuais (compativel com GNSS Survey v2.2)
//
//  COMO USAR ESTE FICHEIRO:
//  1. Xcode > File > New > Project > iOS > App
//     - Product Name: ARStakeout | Interface: SwiftUI | Language: Swift
//  2. Apagar o conteudo de ContentView.swift e do ficheiro <Nome>App.swift
//     e colar TODO este ficheiro num deles (por ex. ContentView.swift).
//     (Se o Xcode criou um App struct duplicado, apague o antigo.)
//  3. Target > Info > adicionar a chave:
//     "Privacy - Camera Usage Description" = "Necessaria para ver as estacas em AR"
//  4. Target > General > Minimum Deployments: iOS 17.0
//  5. Ligar o iPhone por cabo, escolher o dispositivo e Run.
//
//  FLUXO NO TERRENO:
//  1. Importar o KML exportado pela app Android (botao de pasta).
//  2. Pousar o iPhone sobre a marca fisica de um canto -> "Ancorar" -> escolher o canto.
//  3. Caminhar ate um SEGUNDO canto conhecido, pousar -> "Alinhar" -> escolher o canto.
//     A app mostra a verificacao de escala: distancia medida em AR vs distancia no mapa.
//  4. As estacas virtuais aparecem. Verde < 0,3 m | Amarelo 0,3-1 m | Vermelho > 1 m.
//  5. Em cada canto confirmado: "Re-ancorar" para anular a deriva antes de seguir.
//  6. "Registar" guarda o desvio ao canto mais proximo; exportavel em CSV.
//
//  NOTA: a app NAO usa GPS. O alinhamento com 2 pontos do proprio levantamento
//  verifica a GEOMETRIA RELATIVA (fitas/rumos) independentemente do erro absoluto.
//

import SwiftUI
import ARKit
import RealityKit
import Combine
import UniformTypeIdentifiers

// MARK: - Modelo de dados

struct SurveyPoint: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let lat: Double
    let lon: Double
}

// MARK: - Estado da aplicacao

final class AppModel: ObservableObject {

    // Pontos importados do KML
    @Published var points: [SurveyPoint] = []

    // Estado do alinhamento
    @Published var anchorIndex: Int? = nil      // ponto A (origem)
    @Published var aligned: Bool = false        // ja temos rotacao (ponto B)
    @Published var statusText: String = "Importe o KML do levantamento"
    @Published var scaleCheckText: String = ""

    // HUD ao vivo
    @Published var nearestName: String = "--"
    @Published var nearestDistance: Float = 0
    @Published var arrowAngle: Double = 0       // radianos, para rotationEffect
    @Published var hasNearest: Bool = false

    // Registo de desvios
    @Published var logEntries: [String] = []

    // Transformacao ENU -> mundo AR
    // worldA = posicao do ponto ancora no mundo AR; psi = rotacao (rad)
    var worldA: SIMD3<Float>? = nil
    var psi: Float = 0

    // Callback para o coordinator reconstruir as estacas
    var onStakesChanged: (() -> Void)? = nil

    // ENU (metros) de cada ponto relativo ao ponto ancora
    func enu(of p: SurveyPoint) -> SIMD2<Double>? {
        guard let ai = anchorIndex, points.indices.contains(ai) else { return nil }
        let a = points[ai]
        let mLat = 111320.0
        let mLon = 111320.0 * cos(a.lat * .pi / 180)
        let e = (p.lon - a.lon) * mLon
        let n = (p.lat - a.lat) * mLat
        return SIMD2(e, n)
    }

    // Posicao no mundo AR de um ponto (apos alinhamento)
    // Mapa: w = e^{i psi} * (e + i n); x = Re(w); z = -Im(w)  (y = y da ancora)
    func worldPosition(of p: SurveyPoint) -> SIMD3<Float>? {
        guard let wa = worldA, aligned, let u = enu(of: p) else {
            // Antes do alinhamento so a propria ancora tem posicao
            if let ai = anchorIndex, points.indices.contains(ai),
               points[ai] == p, let wa = worldA {
                return wa
            }
            return nil
        }
        let c = Double(cos(psi)); let s = Double(sin(psi))
        let wx = c * u.x - s * u.y
        let wy = s * u.x + c * u.y
        return SIMD3(wa.x + Float(wx), wa.y, wa.z - Float(wy))
    }

    // Passo 2: fixar a ancora na posicao atual da camara
    func setAnchor(pointIndex: Int, cameraPos: SIMD3<Float>) {
        anchorIndex = pointIndex
        worldA = cameraPos
        aligned = false
        scaleCheckText = ""
        statusText = "Ancorado em \(points[pointIndex].name). Va ao 2.o ponto e Alinhar."
        onStakesChanged?()
    }

    // Passo 3: resolver a rotacao com o segundo ponto
    func align(pointIndex: Int, cameraPos: SIMD3<Float>) {
        guard let wa = worldA, let ai = anchorIndex, pointIndex != ai else {
            statusText = "Escolha um ponto DIFERENTE da ancora."
            return
        }
        guard let u = enu(of: points[pointIndex]) else { return }
        let uLen = simd_length(u)
        let wVec = SIMD2(Double(cameraPos.x - wa.x), Double(-(cameraPos.z - wa.z)))
        let wLen = simd_length(wVec)
        if uLen < 0.5 || wLen < 0.5 {
            statusText = "Pontos demasiado proximos para alinhar (>0,5 m)."
            return
        }
        // psi = arg(w) - arg(u)
        let argU = atan2(u.y, u.x)
        let argW = atan2(wVec.y, wVec.x)
        psi = Float(argW - argU)
        aligned = true

        let delta = wLen - uLen
        scaleCheckText = String(
            format: "Verificacao: AR %.2f m vs mapa %.2f m (dif %+.2f m)",
            wLen, uLen, delta
        )
        statusText = "Alinhado. \(points.count) estacas ativas."
        onStakesChanged?()
    }

    // Re-ancorar: translada o sistema para a posicao atual (mantem a rotacao)
    func reAnchor(pointIndex: Int, cameraPos: SIMD3<Float>) {
        guard aligned, let wa = worldA,
              let current = worldPosition(of: points[pointIndex]) else {
            statusText = "Alinhe primeiro (2 pontos)."
            return
        }
        let shift = cameraPos - current
        worldA = wa + shift
        statusText = "Re-ancorado em \(points[pointIndex].name). Deriva anulada."
        onStakesChanged?()
    }

    // Registar desvio ao canto mais proximo
    func logDeviation() {
        guard hasNearest else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = String(
            format: "%@,%.2f,%@",
            nearestName, nearestDistance, df.string(from: Date())
        )
        logEntries.append(line)
        statusText = "Registado: \(nearestName) a \(String(format: "%.2f", nearestDistance)) m"
    }

    var csv: String {
        "ponto,desvio_m,data\n" + logEntries.joined(separator: "\n")
    }

    // MARK: KML

    func importKML(from url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            statusText = "Nao consegui ler o ficheiro."
            return
        }
        var result: [SurveyPoint] = []
        let pmPattern = "<Placemark>([\\s\\S]*?)</Placemark>"
        let namePattern = "<name>([\\s\\S]*?)</name>"
        let ptPattern = "<Point>[\\s\\S]*?<coordinates>([\\s\\S]*?)</coordinates>[\\s\\S]*?</Point>"
        guard let pmRegex = try? NSRegularExpression(pattern: pmPattern),
              let nameRegex = try? NSRegularExpression(pattern: namePattern),
              let ptRegex = try? NSRegularExpression(pattern: ptPattern) else { return }

        let ns = text as NSString
        pmRegex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m, m.numberOfRanges > 1 else { return }
            let block = ns.substring(with: m.range(at: 1))
            let bns = block as NSString
            guard let pt = ptRegex.firstMatch(in: block, range: NSRange(location: 0, length: bns.length)),
                  pt.numberOfRanges > 1 else { return }
            let coord = bns.substring(with: pt.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = coord.components(separatedBy: ",")
            guard parts.count >= 2,
                  let lon = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let lat = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return }
            var nm = "Ponto \(result.count + 1)"
            if let nmM = nameRegex.firstMatch(in: block, range: NSRange(location: 0, length: bns.length)),
               nmM.numberOfRanges > 1 {
                nm = bns.substring(with: nmM.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            result.append(SurveyPoint(name: nm, lat: lat, lon: lon))
        }

        points = result
        anchorIndex = nil
        aligned = false
        worldA = nil
        scaleCheckText = ""
        statusText = result.isEmpty
            ? "KML sem pontos <Point>."
            : "\(result.count) pontos. Pouse no 1.o canto e Ancorar."
        onStakesChanged?()
    }
}

// MARK: - Coordenador AR (estacas, cores, HUD por frame)

// Uma estaca = um ModelEntity raiz com dois filhos guardados explicitamente
// (poste + cabeca), para nao depender de casts fragies sobre .children.
final class Stake {
    let root: ModelEntity
    let pole: ModelEntity
    let head: ModelEntity

    init() {
        pole = ModelEntity(
            mesh: MeshResource.generateBox(width: 0.04, height: 1.2, depth: 0.04),
            materials: [SimpleMaterial(color: UIColor.red, isMetallic: false)]
        )
        pole.position = SIMD3<Float>(0, 0.6, 0)
        head = ModelEntity(
            mesh: MeshResource.generateSphere(radius: 0.07),
            materials: [SimpleMaterial(color: UIColor.red, isMetallic: false)]
        )
        head.position = SIMD3<Float>(0, 1.25, 0)
        root = ModelEntity()
        root.addChild(pole)
        root.addChild(head)
    }

    func setColor(_ color: UIColor) {
        let mat = SimpleMaterial(color: color, isMetallic: false)
        pole.model?.materials = [mat]
        head.model?.materials = [mat]
    }
}

final class ARCoordinator {
    let model: AppModel
    weak var arView: ARView?
    var rootAnchor: AnchorEntity?
    var stakes: [UUID: Stake] = [:]
    var colorBucket: [UUID: Int] = [:]
    var updateSub: Cancellable?

    init(model: AppModel) {
        self.model = model
    }

    func setup() {
        guard let arView = arView else { return }
        let root = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        arView.scene.addAnchor(root)
        rootAnchor = root

        model.onStakesChanged = { [weak self] in
            DispatchQueue.main.async { self?.rebuildStakes() }
        }

        updateSub = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] (_: SceneEvents.Update) in
            self?.perFrame()
        }
    }

    var cameraPosition: SIMD3<Float> {
        arView?.cameraTransform.translation ?? SIMD3<Float>(0, 0, 0)
    }

    func rebuildStakes() {
        guard let root = rootAnchor else { return }
        for (_, s) in stakes { s.root.removeFromParent() }
        stakes.removeAll()
        colorBucket.removeAll()

        for p in model.points {
            guard let pos = model.worldPosition(of: p) else { continue }
            let stake = Stake()
            stake.root.position = pos
            root.addChild(stake.root)
            stakes[p.id] = stake
        }
    }

    func perFrame() {
        guard let arView = arView else { return }
        let camTransform = arView.cameraTransform
        let camPos = camTransform.translation

        var bestDist: Float = Float.greatestFiniteMagnitude
        var bestName = "--"
        var bestPos = SIMD3<Float>(0, 0, 0)
        var found = false

        for p in model.points {
            guard let pos = model.worldPosition(of: p),
                  let stake = stakes[p.id] else { continue }
            let dx = pos.x - camPos.x
            let dz = pos.z - camPos.z
            let d = (dx * dx + dz * dz).squareRoot()   // distancia horizontal

            let bucket = d < 0.3 ? 0 : (d < 1.0 ? 1 : 2)
            if colorBucket[p.id] != bucket {
                colorBucket[p.id] = bucket
                let color: UIColor = bucket == 0 ? UIColor.systemGreen
                    : (bucket == 1 ? UIColor.systemYellow : UIColor.systemRed)
                stake.setColor(color)
            }
            if d < bestDist {
                bestDist = d
                bestName = p.name
                bestPos = pos
                found = true
            }
        }

        // Direcao "para a frente" da camara a partir da coluna z da matriz 4x4.
        // forward = -terceira coluna (convencao ARKit/RealityKit).
        var angle: Double = 0
        if found {
            let m = camTransform.matrix
            let fwdX = -m.columns.2.x
            let fwdZ = -m.columns.2.z
            let headingCam = atan2(Double(fwdX), Double(-fwdZ))
            let vx = bestPos.x - camPos.x
            let vz = bestPos.z - camPos.z
            let headingTarget = atan2(Double(vx), Double(-vz))
            var rel = headingTarget - headingCam
            while rel > Double.pi { rel -= 2 * Double.pi }
            while rel < -Double.pi { rel += 2 * Double.pi }
            angle = rel
        }

        let changed = (model.hasNearest != found) ||
            (abs(model.nearestDistance - bestDist) > 0.01) ||
            (model.nearestName != bestName) ||
            (abs(model.arrowAngle - angle) > 0.02)

        if changed {
            let fFound = found
            let fDist = bestDist
            let fName = bestName
            let fAngle = angle
            DispatchQueue.main.async { [weak self] in
                guard let m = self?.model else { return }
                m.hasNearest = fFound
                if fFound {
                    m.nearestDistance = fDist
                    m.nearestName = fName
                    m.arrowAngle = fAngle
                }
            }
        }
    }
}

// MARK: - UI principal

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showImporter = false
    @State private var pickerMode: PickerMode? = nil
    @State private var coordinatorProxy = CoordinatorProxy()

    enum PickerMode: Identifiable {
        case anchor, align, reanchor
        var id: Int { self == .anchor ? 0 : (self == .align ? 1 : 2) }
        var title: String {
            switch self {
            case .anchor: return "Em que ponto esta pousado o iPhone?"
            case .align: return "Em que ponto esta agora? (2.o ponto)"
            case .reanchor: return "Re-ancorar: em que ponto esta?"
            }
        }
    }

    var body: some View {
        ZStack {
            ARViewWithProxy(model: model, proxy: coordinatorProxy)
                .ignoresSafeArea()

            VStack {
                // ---- Topo: estado ----
                VStack(spacing: 4) {
                    Text(model.statusText)
                        .font(.system(size: 14, weight: .semibold))
                        .multilineTextAlignment(.center)
                    if !model.scaleCheckText.isEmpty {
                        Text(model.scaleCheckText)
                            .font(.system(size: 12))
                            .foregroundColor(.yellow)
                    }
                }
                .padding(10)
                .background(.black.opacity(0.6))
                .foregroundColor(.white)
                .cornerRadius(10)
                .padding(.top, 8)

                Spacer()

                // ---- Seta + distancia ao canto mais proximo ----
                if model.aligned && model.hasNearest {
                    VStack(spacing: 6) {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 44))
                            .rotationEffect(.radians(model.arrowAngle))
                            .foregroundColor(colorFor(model.nearestDistance))
                        Text("\(model.nearestName) - \(String(format: "%.2f", model.nearestDistance)) m")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(12)
                    .background(.black.opacity(0.55))
                    .cornerRadius(14)
                    .padding(.bottom, 10)
                }

                // ---- Barra de botoes ----
                HStack(spacing: 10) {
                    Button { showImporter = true } label: {
                        Image(systemName: "folder")
                            .frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.gray)

                    Button { pickerMode = .anchor } label: {
                        Text("Ancorar").frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.points.isEmpty)

                    Button { pickerMode = .align } label: {
                        Text("Alinhar").frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(model.anchorIndex == nil)

                    Button { pickerMode = .reanchor } label: {
                        Text("Re-anc.").frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(!model.aligned)
                }
                .padding(.horizontal, 10)

                HStack(spacing: 10) {
                    Button { model.logDeviation() } label: {
                        Label("Registar desvio", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .disabled(!(model.aligned && model.hasNearest))

                    ShareLink(item: model.csv) {
                        Label("CSV (\(model.logEntries.count))", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.logEntries.isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "kml") ?? .xml, .xml, .data
            ]
        ) { result in
            if case .success(let url) = result {
                model.importKML(from: url)
            }
        }
        .confirmationDialog(
            pickerMode?.title ?? "",
            isPresented: Binding(
                get: { pickerMode != nil },
                set: { if !$0 { pickerMode = nil } }
            ),
            titleVisibility: .visible
        ) {
            ForEach(Array(model.points.enumerated()), id: \.element.id) { idx, p in
                Button(p.name) {
                    let cam = coordinatorProxy.cameraPosition()
                    switch pickerMode {
                    case .anchor: model.setAnchor(pointIndex: idx, cameraPos: cam)
                    case .align: model.align(pointIndex: idx, cameraPos: cam)
                    case .reanchor: model.reAnchor(pointIndex: idx, cameraPos: cam)
                    case .none: break
                    }
                    pickerMode = nil
                }
            }
            Button("Cancelar", role: .cancel) { pickerMode = nil }
        }
    }

    private func colorFor(_ d: Float) -> Color {
        d < 0.3 ? .green : (d < 1.0 ? .yellow : .red)
    }
}

// Proxy para a UI conseguir ler a posicao da camara guardada no coordinator
final class CoordinatorProxy {
    var getCamera: (() -> SIMD3<Float>)? = nil
    func cameraPosition() -> SIMD3<Float> { getCamera?() ?? .zero }
}

struct ARViewWithProxy: UIViewRepresentable {
    @ObservedObject var model: AppModel
    let proxy: CoordinatorProxy

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        arView.session.run(config)
        context.coordinator.arView = arView
        context.coordinator.setup()
        proxy.getCamera = { [weak coordinator = context.coordinator] in
            coordinator?.cameraPosition ?? .zero
        }
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> ARCoordinator {
        ARCoordinator(model: model)
    }
}

// MARK: - App

@main
struct ARStakeoutApp: App {
    var body: WindowGroup<ContentView> {
        WindowGroup {
            ContentView()
        }
    }
}
