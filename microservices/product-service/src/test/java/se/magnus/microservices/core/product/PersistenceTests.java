package se.magnus.microservices.core.product;

import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.data.mongo.DataMongoTest;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.dao.OptimisticLockingFailureException;
import org.springframework.test.context.junit4.SpringRunner;
import reactor.test.StepVerifier;
import se.magnus.microservices.core.product.persistence.ProductEntity;
import se.magnus.microservices.core.product.persistence.ProductRepository;

@RunWith(SpringRunner.class)
@DataMongoTest(properties = { "spring.cloud.config.enabled=false" })
public class PersistenceTests {
    @Autowired
    private ProductRepository repository;

    private ProductEntity savedEntity;

    @Before
    public void setUpDb() {
        StepVerifier.create(repository.deleteAll()).verifyComplete();

        ProductEntity entity = new ProductEntity(1, "n", 1);
        StepVerifier.create(repository.save(entity))
                .expectNextMatches(createdEntity -> {
                    savedEntity = createdEntity;
                    return areProductEqual(entity, savedEntity);
                })
                .verifyComplete();
    }

    @Test
    public void create() {
        ProductEntity newEntity = new ProductEntity(2, "n", 2);

        StepVerifier.create(repository.save(newEntity))
                .expectNextMatches(createdEntity -> newEntity.getProductId() == createdEntity.getProductId())
                .verifyComplete();

        StepVerifier.create(repository.findById(newEntity.getId()))
                .expectNextMatches(foundEntity -> areProductEqual(newEntity, foundEntity))
                .verifyComplete();

        StepVerifier.create(repository.count()).expectNext(2l).verifyComplete();
    }

    @Test
    public void update() {
        savedEntity.setName("n2");

        StepVerifier.create(repository.save(savedEntity))
                .expectNextMatches(updatedEntity -> updatedEntity.getName().equals("n2"))
                .verifyComplete();

        StepVerifier.create(repository.findById(savedEntity.getId()))
                .expectNextMatches(foundEntity ->
                        foundEntity.getVersion() == 1 &&
                        foundEntity.getName().equals("n2"))
                .verifyComplete();
    }

    @Test
    public void delete() {
        StepVerifier.create(repository.delete(savedEntity)).verifyComplete();
        StepVerifier.create(repository.existsById(savedEntity.getId())).expectNext(false).verifyComplete();
    }

    @Test
    public void getByProductId() {
        StepVerifier.create(repository.findByProductId(savedEntity.getProductId()))
                .expectNextMatches(foundEntity -> areProductEqual(savedEntity, foundEntity))
                .verifyComplete();
    }

    @Test
    public void duplicateError() {
        ProductEntity entity = new ProductEntity(savedEntity.getProductId(), "n", 1);
        StepVerifier.create(repository.save(entity)).expectError(DuplicateKeyException.class).verify();
    }

    @Test
    public void optimisticLockError() {
        ProductEntity entity1 = repository.findById(savedEntity.getId()).block();
        ProductEntity entity2 = repository.findById(savedEntity.getId()).block();

        entity1.setName("n1");
        repository.save(entity1).block();

        StepVerifier.create(repository.save(entity2)).expectError(OptimisticLockingFailureException.class).verify();

        StepVerifier.create(repository.findById(savedEntity.getId()))
                .expectNextMatches(foundEntity ->
                        foundEntity.getVersion() == 1 &&
                        foundEntity.getName().equals("n1"))
                .verifyComplete();
    }

    private boolean areProductEqual(ProductEntity expectedEntity, ProductEntity actualEntity) {
        return
            (expectedEntity.getId().equals(actualEntity.getId())) &&
            (expectedEntity.getVersion().equals(actualEntity.getVersion())) &&
            (expectedEntity.getProductId() == actualEntity.getProductId()) &&
            (expectedEntity.getName().equals(actualEntity.getName())) &&
            (expectedEntity.getWeight() == actualEntity.getWeight());


    }

    /* JPA Blocking Test
    @Before
    public void setUpDb() {
        repository.deleteAll();

        ProductEntity entity = new ProductEntity(1, "n", 1);
        savedEntity = repository.save(entity);

        assertEqualsProduct(entity, savedEntity);
    }

    @Test
    public void create() {
        ProductEntity newEntity = new ProductEntity(2, "n", 2);
        repository.save(newEntity);

        ProductEntity foundEntity = repository.findById(newEntity.getId()).get();
        assertEqualsProduct(newEntity, foundEntity);

        assertEquals(2, repository.count());
    }

    @Test
    public void update() {
        savedEntity.setName("n2");
        repository.save(savedEntity);

        ProductEntity foundEntity = repository.findById(savedEntity.getId()).get();

        assertEquals(1, (long) foundEntity.getVersion());
        assertEquals("n2", foundEntity.getName());
    }

    @Test
    public void delete() {
        repository.delete(savedEntity);
        assertFalse(repository.existsById(savedEntity.getId()));
    }

    @Test
    public void getByProductId() {
        Optional<ProductEntity> entity = repository.findByProductId(savedEntity.getProductId());

        assertTrue(entity.isPresent());
        assertEqualsProduct(savedEntity, entity.get());
    }

    @Test(expected = DuplicateKeyException.class)
    public void duplicateError() {
        ProductEntity entity = new ProductEntity(savedEntity.getProductId(), "n", 1);
        repository.save(entity);
    }

    @Test
    public void optimisticLockError() {
        // 데이터베이스에서 가져온 엔티티를 변수 2개에 저장
        ProductEntity entity1 = repository.findById(savedEntity.getId()).get();
        ProductEntity entity2 = repository.findById(savedEntity.getId()).get();

        // 첫 번째 엔티티 객체를 업데이트
        entity1.setName("n1");
        repository.save(entity1);

        // 두 번째 엔티티 객체를 업데이트
        // 두 번째 엔티티 객체의 버전이 낮으므로 실패 -> Optimistic Lock Error
        try {
            entity2.setName("n2");
            repository.save(entity2);
            fail("Expected an OptimisticLockingFailureException");
        } catch (OptimisticLockingFailureException e) {}

        // Get the updated entity from the database and verify its new state
        ProductEntity updatedEntity = repository.findById(savedEntity.getId()).get();
        assertEquals(1, (int) updatedEntity.getVersion());
        assertEquals("n1", updatedEntity.getName());
    }

    @Test
    public void paging() {
        repository.deleteAll();

        List<ProductEntity> newProducts = rangeClosed(1001, 1010)
                .mapToObj(i -> new ProductEntity(i, "name " + i, i))
                .collect(Collectors.toList());
        repository.saveAll(newProducts);

        Pageable nextPage = PageRequest.of(0, 4, ASC, "productId");
        nextPage = testNextPage(nextPage, "[1001, 1002, 1003, 1004]", true);
        nextPage = testNextPage(nextPage, "[1005, 1006, 1007, 1008]", true);
        nextPage = testNextPage(nextPage, "[1009, 1010]", false);
    }

    private Pageable testNextPage(Pageable nextPage, String expectedProductIds, boolean expectsNextPage) {
        Page<ProductEntity> productPage = repository.findAll(nextPage);
        assertEquals(expectedProductIds, productPage.getContent().stream().map(p -> p.getProductId()).collect(Collectors.toList()).toString());
        return productPage.nextPageable();
    }

    private void assertEqualsProduct(ProductEntity expectedEntity, ProductEntity actualEntity) {
        assertEquals(expectedEntity.getId(), actualEntity.getId());
        assertEquals(expectedEntity.getVersion(), actualEntity.getVersion());
        assertEquals(expectedEntity.getProductId(), actualEntity.getProductId());
        assertEquals(expectedEntity.getName(), actualEntity.getName());
        assertEquals(expectedEntity.getWeight(), actualEntity.getWeight());
    }
    */
}
